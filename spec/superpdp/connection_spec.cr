# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Superpdp::SpecSupport
private alias Api = Superpdp::Api
private alias E = Einvoicing::SpecSupport

private def stored_row : Einvoicing::Connection
  Einvoicing::Connection.filter(adapter: "SUPERPDP").first!
end

describe "Raccordement SUPER PDP : OAuth 2.1 en deux modes (ADR-004 D8)" do
  it "s'enregistre comme adaptateur d'EINV, sous la dépendance d'EINV, avec sa permission de raccordement" do
    adapter = Einvoicing::Connections.adapter?("SUPERPDP") || raise "adaptateur absent"
    adapter.regimes.should eq(%w[fr be])
    adapter.fields.map { |field| {field.name, field.secret, field.required} }.should eq([{"client_id", false, false},
                                                                                         {"client_secret", true, false}])
    manifest = Partiduo::Modules["SUPERPDP"]
    manifest.depends_on.should eq(["EINV"])
    manifest.permissions.should eq(["superpdp.connection.manage"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route, menu.permission} }
      .should eq([{"SUPERPDP", "SETTINGS", "superpdp:index", "superpdp.connection.manage"}])
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) { keys.each { |key| I18n.t(key).should_not contain("missing") } }
    end
  end

  it "refuse de s'activer sans EINV" do
    with_active_modules("") do
      PartiduoUi::Reference.provision("fr")
      result = Partiduo::Api::Modules.activate(S::SYSTEM, "SUPERPDP")
      result.errors.first.key.should eq("modules.errors.activation.missing_dependency")
    end
  end

  it "refuse son contrat sans la permission de raccordement" do
    S.books
    expect_raises(Partiduo::Api::Forbidden) { Api.status(E.reader) }
  end

  it "raccorde en client credentials : identifiants essayés, secret chiffré, mode déduit des identifiants" do
    S.books
    company = S.company
    status = Api.status(S.admin)
    {status.connected, status.auth_mode, status.env_known}.should eq({false, "", false})
    refused = Api.connect_credentials(S.admin, Api::CredentialsInput.new(company.client_id, "mauvais"))
    refused.errors.map(&.key).should eq(["superpdp.errors.credentials.refused"])
    Einvoicing::Connection.filter(adapter: "SUPERPDP").exists?.should be_false
    Api.connect_credentials(S.admin, Api::CredentialsInput.new("", "")).errors.map(&.field).should eq(%w[client_id client_secret])

    status = S.connect(company)
    {status.connected, status.auth_mode, status.mode, status.env_known}.should eq({true, "client_credentials", "sandbox", true})
    {status.company_name, status.company_number, status.verification_status}.should eq({"Atelier Brunet SARL", E::COMPANY_SIREN, "verified"})
    Einvoicing::Api.connection(S.admin).try(&.mode).should eq("sandbox")
    Einvoicing::Api.connection(S.admin).try(&.adapter).should eq("SUPERPDP")
    row = stored_row
    row.secrets.to_s.should start_with("v1:")
    row.secrets.to_s.should_not contain(company.client_secret)
    row.access_token.to_s.should start_with("v1:")
    row.refresh_token.to_s.should be_empty
    # Le secret enregistré est gardé quand on le laisse vide.
    Api.connect_credentials(S.admin, Api::CredentialsInput.new(company.client_id, "")).success?.should be_true
    # En production, le mode suit l'entreprise des identifiants.
    company.env = "production"
    Api.check(S.admin).value!.mode.should eq("production")
    Einvoicing::Api.connection(S.admin).try(&.mode).should eq("production")
  end

  it "renouvelle automatiquement le jeton d'accès à l'expiration et sur un refus 401" do
    S.books
    S.connect
    connector = S.connector
    connector.company["formal_name"].should eq("Atelier Brunet SARL")
    tokens = S.platform.requests.count(&.url.ends_with?("/oauth2/token"))
    connector.company
    S.platform.requests.count(&.url.ends_with?("/oauth2/token")).should eq(tokens)
    S.platform.expire_access_tokens!
    connector.company["formal_name"].should eq("Atelier Brunet SARL")
    S.platform.requests.count(&.url.ends_with?("/oauth2/token")).should eq(tokens + 1)
  end

  it "signale une entreprise pas encore vérifiée par SUPER PDP (KYB)" do
    S.books
    S.connect
    S.company.verification = "needs_review"
    Api.check(S.admin).errors.map(&.key).should eq(["superpdp.errors.connection.not_verified"])
    Api.status(S.admin).verification_status.should eq("needs_review")
  end

  it "raccorde en authorization code : parcours pré-rempli, state anti-CSRF, PKCE, retour sur l'instance" do
    S.books
    company = S.company
    Api.start_authorization(S.admin, Api::AuthorizationInput.new(redirect_uri: S::SimulatedSuperpdp::REDIRECT_URI))
      .errors.map(&.key).should eq(["superpdp.errors.authorization.unavailable"])
    S.with_operator do
      Api.status(S.admin).authorization_available.should be_true
      defaults = Api.authorization_defaults(S.admin, S::SimulatedSuperpdp::REDIRECT_URI, "admin@brunet.test")
      {defaults.company_number, defaults.company_number_scheme, defaults.login_hint}.should eq({E::COMPANY_SIREN, "fr_siren", "admin@brunet.test"})
      invalid = Api.start_authorization(S.admin, Api::AuthorizationInput.new(redirect_uri: "http://evil.test/cb",
        login_hint: "pas un courriel", company_number: "123456789", company_number_scheme: "fr_siren"))
      invalid.errors.map(&.field).should eq(%w[redirect_uri login_hint company_number])

      start = Api.start_authorization(S.admin, defaults).value!
      url = URI.parse(start.url)
      {url.host, url.path}.should eq({"api.superpdp.tech", "/oauth2/authorize"})
      params = url.query_params
      params["login_hint"].should eq("admin@brunet.test")
      {params["superpdp_company_number"], params["superpdp_company_number_scheme"]}.should eq({E::COMPANY_SIREN, "fr_siren"})
      {params["redirect_uri"], params["code_challenge_method"], params["client_id"]}
        .should eq({S::SimulatedSuperpdp::REDIRECT_URI, "S256", S::SimulatedSuperpdp::OPERATOR_CLIENT_ID})
      params["state"].size.should be >= 32
      # Le state n'est conservé que par son empreinte ; le vérificateur PKCE est chiffré.
      request = Superpdp::Authorization.all.first!
      request.state_digest.should eq(Digest::SHA256.hexdigest(params["state"]))
      request.code_verifier.to_s.should start_with("v1:")

      code, state = S.platform.consent(start.url, company)
      # Un state inconnu, ou lancé par un autre utilisateur, est refusé.
      Api.complete_authorization(S.admin, Api::CallbackInput.new(state: "inconnu", code: code))
        .errors.map(&.key).should eq(["superpdp.errors.authorization.state"])
      other = Partiduo::Api::Actor.user(999_i64, E::PERMISSIONS + [Api::CONFIGURE], level: 3)
      Api.complete_authorization(other, Api::CallbackInput.new(state: state, code: code))
        .errors.map(&.key).should eq(["superpdp.errors.authorization.state"])
      status = Api.complete_authorization(S.admin, Api::CallbackInput.new(state: state, code: code)).value!
      {status.connected, status.auth_mode, status.mode, status.client_id}.should eq({true, "authorization_code", "sandbox", ""})
      stored_row.refresh_token.to_s.should start_with("v1:")
      Superpdp::Account.current!.login_hint.should eq("admin@brunet.test")
      # À usage unique.
      Api.complete_authorization(S.admin, Api::CallbackInput.new(state: state, code: code))
        .errors.map(&.key).should eq(["superpdp.errors.authorization.state"])
    end
  end

  it "rend compte d'un refus de l'utilisateur et d'une demande expirée" do
    S.books
    S.with_operator do
      start = Api.start_authorization(S.admin, Api::AuthorizationInput.new(redirect_uri: S::SimulatedSuperpdp::REDIRECT_URI)).value!
      state = URI.parse(start.url).query_params["state"]
      denied = Api.complete_authorization(S.admin, Api::CallbackInput.new(state: state, error: "access_denied"))
      denied.errors.map(&.key).should eq(["superpdp.errors.authorization.denied"])
      start = Api.start_authorization(S.admin, Api::AuthorizationInput.new(redirect_uri: S::SimulatedSuperpdp::REDIRECT_URI)).value!
      code, state = S.platform.consent(start.url, S.company)
      Superpdp::Authorization.all.update(expires_at: Time.utc - 1.minute)
      Api.complete_authorization(S.admin, Api::CallbackInput.new(state: state, code: code))
        .errors.map(&.key).should eq(["superpdp.errors.authorization.state"])
      Api.status(S.admin).connected.should be_false
    end
  end

  it "renouvelle le jeton de rafraîchissement à chaque usage (rotation), chiffré" do
    S.books
    S.with_operator do
      S.authorize
      first = Einvoicing::Secrets.decrypt(stored_row.refresh_token.to_s)
      S.platform.refresh_tokens.should eq([first])
      S.platform.expire_access_tokens!
      Einvoicing::Connection.filter(adapter: "SUPERPDP").update(access_token: "", access_token_expires_at: nil)
      S.connector.company["formal_name"].should eq("Atelier Brunet SARL")
      second = Einvoicing::Secrets.decrypt(stored_row.refresh_token.to_s)
      second.should_not eq(first)
      S.platform.refresh_tokens.should eq([second])
      # Le jeton suivant sert à son tour, une seule fois.
      Einvoicing::Connection.filter(adapter: "SUPERPDP").update(access_token: "", access_token_expires_at: nil)
      S.connector.company
      Einvoicing::Secrets.decrypt(stored_row.refresh_token.to_s).should_not eq(second)
    end
  end

  it "demande de se raccorder de nouveau quand le jeton de rafraîchissement est refusé" do
    S.books
    S.with_operator do
      S.authorize
      # Jeton révoqué côté SUPER PDP (compte abandonné, révocation ailleurs).
      S.platform.forget_refresh_tokens!
      Einvoicing::Connection.filter(adapter: "SUPERPDP").update(access_token: "", access_token_expires_at: nil)
      Api.check(S.admin).errors.map(&.key).should eq(["superpdp.errors.connection.authorization"])
      stored_row.refresh_token.to_s.should be_empty
      Einvoicing::Api.synchronize(E.admin).value!.errors.first.should contain("autorisation SUPER PDP")
    end
  end

  it "déconnecte en révoquant les jetons (RFC 7009) ; EINV est débranché" do
    S.books
    S.with_operator do
      S.authorize
      refresh = Einvoicing::Secrets.decrypt(stored_row.refresh_token.to_s)
      access = Einvoicing::Secrets.decrypt(stored_row.access_token.to_s)
      Api.disconnect(S.admin).success?.should be_true
      S.platform.revoked.should eq([refresh, access])
      Api.status(S.admin).connected.should be_false
      Einvoicing::Api.connection(S.admin).should be_nil
      stored_row.refresh_token.to_s.should be_empty
      stored_row.access_token.to_s.should be_empty
    end
  end

  it "révoque l'autorisation précédente en passant en client credentials" do
    S.books
    S.with_operator do
      S.authorize
      refresh = Einvoicing::Secrets.decrypt(stored_row.refresh_token.to_s)
      S.connect.auth_mode.should eq("client_credentials")
      S.platform.revoked.should contain(refresh)
      stored_row.refresh_token.to_s.should be_empty
    end
  end

  it "contrôle les numéros d'entreprise : SIREN (Luhn), numéro belge (modulo 97)" do
    Superpdp::Linking.valid_number?("732829320", "fr_siren").should be_true
    Superpdp::Linking.valid_number?("732829321", "fr_siren").should be_false
    Superpdp::Linking.valid_number?("0417497106", "be_numero_entreprise").should be_true
    Superpdp::Linking.valid_number?("0417497107", "be_numero_entreprise").should be_false
    Superpdp::Linking.redirect_uri?("http://demo.partiduo.localhost:8000/ext/SUPERPDP/oauth/callback").should be_true
    Superpdp::Linking.redirect_uri?("http://demo.example.test/cb").should be_false
    challenge = Superpdp::OAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    challenge.should eq("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM") # RFC 7636, annexe B
  end

  it "propose pour un dossier belge le numéro d'entreprise tiré du numéro de TVA" do
    S.books("be")
    defaults = Api.authorization_defaults(S.admin, S::SimulatedSuperpdp::REDIRECT_URI)
    {defaults.company_number, defaults.company_number_scheme}.should eq({"0417497106", "be_numero_entreprise"})
  end
end
