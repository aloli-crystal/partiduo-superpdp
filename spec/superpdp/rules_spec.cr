# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Cas limites, permissions, module inactif et intégrité en base de
# l'adaptateur SUPER PDP (lot E, testeur) : OAuth 2.1 (state à usage unique,
# PKCE), enregistrement soumis aux permissions d'EINV, contraintes des
# tables `superpdp_*`.

private alias S = Superpdp::SpecSupport
private alias Api = Superpdp::Api
private alias E = Einvoicing::SpecSupport

private def sql(query : String, *args) : Nil
  Marten::DB::Connection.default.open(&.exec(query, *args))
end

private def start_state : String
  start = Api.start_authorization(S.admin, Api::AuthorizationInput.new(redirect_uri: S::SimulatedSuperpdp::REDIRECT_URI)).value!
  URI.parse(start.url).query_params["state"]
end

# Titulaire de la seule permission de SUPERPDP, sans celle d'EINV.
private def linker_only : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(S.admin.user_id || 1_i64, [Api::CONFIGURE, E::Api::READ], level: 3)
end

describe "SUPER PDP : règles, cas limites et intégrité (lot E)" do
  it "consomme le state même quand le retour signale une erreur ou omet le code" do
    S.books
    S.with_operator do
      state = start_state
      Api.complete_authorization(S.admin, Api::CallbackInput.new(state: state, error: "access_denied",
        error_description: "refus")).errors.map(&.key).should eq(["superpdp.errors.authorization.denied"])
      Api.complete_authorization(S.admin, Api::CallbackInput.new(state: state, code: "abc"))
        .errors.map(&.key).should eq(["superpdp.errors.authorization.state"])

      state = start_state
      Api.complete_authorization(S.admin, Api::CallbackInput.new(state: state))
        .errors.map(&.key).should eq(["superpdp.errors.authorization.code"])
      Superpdp::Authorization.filter(used_at: nil).count.should eq(0)
      Api.complete_authorization(S.admin, Api::CallbackInput.new(state: ""))
        .errors.map(&.key).should eq(["superpdp.errors.authorization.state"])
      Api.status(S.admin).connected.should be_false
    end
  end

  it "garde utilisable un state présenté par un autre utilisateur" do
    S.books
    S.with_operator do
      start = Api.start_authorization(S.admin, Api::AuthorizationInput.new(redirect_uri: S::SimulatedSuperpdp::REDIRECT_URI,
        login_hint: S.company.email, company_number: S.company.number, company_number_scheme: "fr_siren")).value!
      code, state = S.platform.consent(start.url, S.company)
      intruder = Partiduo::Api::Actor.user(999_i64, E::PERMISSIONS + [Api::CONFIGURE], level: 3)
      Api.complete_authorization(intruder, Api::CallbackInput.new(state: state, code: code))
        .errors.map(&.key).should eq(["superpdp.errors.authorization.state"])
      Api.complete_authorization(S.admin, Api::CallbackInput.new(state: state, code: code)).value!.connected.should be_true
    end
  end

  it "efface les demandes d'autorisation expirées depuis plus d'un jour" do
    S.books
    S.with_operator do
      start_state
      Superpdp::Authorization.all.update(expires_at: Time.utc - 2.days)
      start_state
      Superpdp::Authorization.all.count.should eq(1)
    end
  end

  it "contrôle l'adresse de retour et le numéro d'entreprise du parcours" do
    Superpdp::Linking.redirect_uri?("https://compta.example.fr/ext/SUPERPDP/oauth/callback").should be_true
    Superpdp::Linking.redirect_uri?("http://127.0.0.1:8000/cb").should be_true
    Superpdp::Linking.redirect_uri?("http://localhost/cb").should be_true
    Superpdp::Linking.redirect_uri?("javascript:alert(1)").should be_false
    Superpdp::Linking.redirect_uri?("https://").should be_false
    Superpdp::Linking.redirect_uri?("https://a.fr/#{"x" * 2000}").should be_false
    Superpdp::Linking.valid_number?("732829320", "").should be_false
    Superpdp::Linking.valid_number?("73282932", "fr_siren").should be_false
    Superpdp::Linking.valid_number?("2417497106", "be_numero_entreprise").should be_false
    Superpdp::Linking.valid_number?("000000097", "sandbox").should be_true
    Superpdp::Linking.valid_number?("12a", "sandbox").should be_false
    S.books
    S.with_operator do
      # Le numéro peut être saisi avec points et espaces.
      Api.start_authorization(S.admin, Api::AuthorizationInput.new(redirect_uri: S::SimulatedSuperpdp::REDIRECT_URI,
        company_number: "732 829 320", company_number_scheme: "fr_siren")).success?.should be_true
      Superpdp::Authorization.all.first!.company_number.should eq("732829320")
    end
  end

  it "borne les identifiants d'application et garde le secret enregistré pour le même identifiant" do
    S.books
    company = S.company
    Api.connect_credentials(S.admin, Api::CredentialsInput.new("x" * 201, "y")).errors.map(&.key)
      .should eq(["superpdp.errors.credentials.too_long"])
    S.connect(company)
    Api.connect_credentials(S.admin, Api::CredentialsInput.new(company.client_id, "  ")).success?.should be_true
    # Un autre identifiant sans secret : rien n'est repris.
    Api.connect_credentials(S.admin, Api::CredentialsInput.new("autre-client", "")).errors.map(&.field)
      .should eq(["client_secret"])
  end

  it "exige la permission d'EINV avant tout appel à SUPER PDP ; un refus ne révoque rien" do
    S.books
    S.with_operator do
      S.authorize
      expect_raises(Partiduo::Api::Forbidden) { Api.disconnect(linker_only) }
      S.platform.revoked.should be_empty
      Api.status(S.admin).connected.should be_true
      expect_raises(Partiduo::Api::Forbidden) do
        Api.connect_credentials(linker_only, Api::CredentialsInput.new(S.company.client_id, S.company.client_secret))
      end
      S.platform.revoked.should be_empty
      expect_raises(Partiduo::Api::Forbidden) do
        Api.start_authorization(linker_only, Api::AuthorizationInput.new(redirect_uri: S::SimulatedSuperpdp::REDIRECT_URI))
      end
      expect_raises(Partiduo::Api::Forbidden) do
        Api.complete_authorization(linker_only, Api::CallbackInput.new(state: "x", code: "y"))
      end
      # Le régime de TVA change le paramétrage de l'entreprise chez SUPER PDP.
      expect_raises(Partiduo::Api::Forbidden) do
        Api.update_vat_regime(linker_only, Api::VatRegimeInput.new("monthly"))
      end
      Api.status(linker_only).connected.should be_true
      Einvoicing::Api.connection(S.admin).try(&.adapter).should eq("SUPERPDP")
    end
  end

  it "répond sans raccordement : vérification, lignes d'annuaire, régime de TVA ; déconnexion idempotente" do
    S.books
    Api.check(S.admin).errors.map(&.key).should eq(["superpdp.errors.connection.missing"])
    Api.directory_lines(S.admin).errors.map(&.key).should eq(["superpdp.errors.connection.missing"])
    Api.update_vat_regime(S.admin, Api::VatRegimeInput.new("monthly")).errors.map(&.key)
      .should eq(["superpdp.errors.connection.missing"])
    Api.update_vat_regime(S.admin, Api::VatRegimeInput.new("mensuel")).errors.map(&.key)
      .should eq(["superpdp.errors.vat_regime.invalid"])
    Api.disconnect(S.admin).success?.should be_true
    Api.disconnect(S.admin).success?.should be_true
    status = Api.status(S.admin)
    {status.connected, status.mode, status.env_known, status.authorization_available}.should eq({false, "sandbox", false, false})
  end

  it "signale un autre adaptateur d'EINV actif, et le remplace en se raccordant" do
    S.books
    E.connect_afnor
    Api.status(S.admin).other_adapter.should eq("AFNOR")
    S.connect
    status = Api.status(S.admin)
    {status.connected, status.other_adapter}.should eq({true, nil})
    Einvoicing::Connection.filter(active: true).count.should eq(1)
  end

  it "refuse tout le contrat quand l'extension est désactivée, ou sans permission" do
    S.books
    expect_raises(Partiduo::Api::Forbidden) { Api.check(E.admin) }
    expect_raises(Partiduo::Api::Forbidden) { Api.directory_lines(E.admin) }
    expect_raises(Partiduo::Api::Forbidden) { Api.update_vat_regime(E.admin, Api::VatRegimeInput.new("monthly")) }
    expect_raises(Partiduo::Api::Forbidden) { Api.authorization_defaults(E.admin, S::SimulatedSuperpdp::REDIRECT_URI) }
    Partiduo::Api::Modules.deactivate(S::SYSTEM, "SUPERPDP").success?.should be_true
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.status(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.check(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.disconnect(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) do
      Api.connect_credentials(S.admin, Api::CredentialsInput.new("a", "b"))
    end
  end

  it "garantit en base le compte unique, les modes et l'état des dépôts et des messages" do
    S.books
    S.connect
    {
      "superpdp_account_key_check"       => "UPDATE superpdp_account SET key = 'second'",
      "superpdp_account_auth_mode_check" => "UPDATE superpdp_account SET auth_mode = 'password'",
      "superpdp_account_env_check"       => "UPDATE superpdp_account SET env = 'staging'",
    }.each do |constraint, query|
      expect_raises(Exception, /#{constraint}/) { sql(query) }
    end
    ref = "INSERT INTO superpdp_invoice_ref (platform_id, direction, external_id, state, created_at, updated_at) " \
          "VALUES ($1, $2, $3, $4, now(), now())"
    expect_raises(Exception, /superpdp_invoice_ref_direction_check/) { sql(ref, 1_i64, "io", "e1", "created") }
    expect_raises(Exception, /superpdp_invoice_ref_state_check/) { sql(ref, 1_i64, "out", "e1", "lost") }
    expect_raises(Exception, /superpdp_invoice_ref_created_check/) { sql(ref, nil, "out", "e1", "created") }
    sql(ref, nil, "out", "e1", "pending")
    expect_raises(Exception, /unique|duplicate/i) { sql(ref, nil, "out", "e1", "pending") }
    message = "INSERT INTO superpdp_sent_message (key, kind, platform_id, state, created_at, updated_at) " \
              "VALUES ($1, $2, $3, $4, now(), now())"
    expect_raises(Exception, /superpdp_sent_message_kind_check/) { sql(message, "k1", "invoice", 1_i64, "sent") }
    expect_raises(Exception, /superpdp_sent_message_state_check/) { sql(message, "k1", "event", 1_i64, "lost") }
    expect_raises(Exception, /superpdp_sent_message_sent_check/) { sql(message, "k1", "event", nil, "sent") }
    sql(message, "k1", "event", nil, "pending")
    expect_raises(Exception, /unique|duplicate/i) { sql(message, "k1", "b2c_payment", nil, "pending") }
  end
end
