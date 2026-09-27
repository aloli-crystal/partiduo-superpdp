# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Superpdp::SpecSupport
private alias E = Einvoicing::SpecSupport

private def signed_in : PartiduoUi::Browser
  S.books
  PartiduoUi::Accounts.signed_in
end

describe "Écrans SUPER PDP sous /ext/SUPERPDP/ (ADR-005 D4)" do
  it "est montée sous le code de l'extension, avec la permission de raccordement" do
    Marten.routes.reverse("superpdp:index").should eq("/ext/SUPERPDP/")
    Marten.routes.reverse("superpdp:callback").should eq("/ext/SUPERPDP/oauth/callback")
    mount = PartiduoUi::Extensions["SUPERPDP"]? || raise("interface non montée")
    mount.permission.should eq(Superpdp::Api::CONFIGURE)
  end

  it "n'existe pas tant que l'extension est inactive (404)" do
    E.books
    PartiduoUi::Accounts.signed_in.get("/ext/SUPERPDP/").status.should eq(404)
  end

  it "raccorde par les identifiants d'une application : erreur, puis état de la connexion avec le mode" do
    browser = signed_in
    company = S.company
    html = browser.get("/ext/SUPERPDP/").html
    html.should contain("<h1>Plateforme agréée SUPER PDP")
    html.should contain("SUPER PDP n'est pas raccordé")
    html.should contain(%(data-superpdp-form="client_credentials"))
    html.should contain(%(data-superpdp-unavailable))
    refused = browser.post("/ext/SUPERPDP/connect", {"client_id" => company.client_id, "client_secret" => "faux"})
    refused.status.should eq(422)
    refused.html.should contain("SUPER PDP refuse ces identifiants.")
    refused.html.should_not contain("faux")
    ok = browser.post("/ext/SUPERPDP/connect", {"client_id" => company.client_id, "client_secret" => company.client_secret})
    ok.status.should eq(302)
    html = browser.get("/ext/SUPERPDP/").html
    html.should contain("SUPER PDP est raccordé (Bac à sable).")
    html.should contain(%(data-superpdp-mode="sandbox"))
    html.should contain(%(data-superpdp-auth="client_credentials"))
    html.should contain("Atelier Brunet SARL")
    html.should contain(%(data-superpdp-verification="verified"))
    html.should contain("0225:#{E::COMPANY_SIREN}_replyto")
    html.should contain("Enregistré — laissez vide pour le garder")
    html.should_not contain(company.client_secret)
    # Le mode est aussi rappelé sur les écrans d'EINV.
    browser.get("/ext/EINV/incoming").html.should contain(%(data-einv-mode="sandbox"))
    browser.get("/ext/EINV/settings").html.should contain("SUPER PDP (API JSON, France et Belgique)")
  end

  it "raccorde par le compte SUPER PDP : redirection pré-remplie, retour sur la route de rappel" do
    browser = signed_in
    S.with_operator do
      html = browser.get("/ext/SUPERPDP/").html
      html.should contain(%(name="company_number" value="#{E::COMPANY_SIREN}"))
      response = browser.post("/ext/SUPERPDP/authorize", {"login_hint" => "admin@brunet.test",
                                                          "company_number" => E::COMPANY_SIREN, "company_number_scheme" => "fr_siren"})
      response.status.should eq(302)
      location = response.headers["Location"]
      location.should start_with("https://api.superpdp.tech/oauth2/authorize?")
      params = URI.parse(location).query_params
      params["redirect_uri"].should end_with("/ext/SUPERPDP/oauth/callback")
      params["login_hint"].should eq("admin@brunet.test")
      code, state = S.platform.consent(location, S.company)
      back = browser.get("/ext/SUPERPDP/oauth/callback?#{URI::Params.encode({"state" => state, "code" => code})}")
      back.headers["Location"].should eq("/ext/SUPERPDP/")
      html = browser.get("/ext/SUPERPDP/").html
      html.should contain("SUPER PDP est raccordé (Bac à sable).")
      html.should contain(%(data-superpdp-auth="authorization_code"))
      # Un retour rejoué est refusé.
      browser.get("/ext/SUPERPDP/oauth/callback?#{URI::Params.encode({"state" => state, "code" => code})}")
      browser.get("/ext/SUPERPDP/").html.should contain("Retour d'autorisation inconnu, expiré ou déjà utilisé")
    end
  end

  it "vérifie, enregistre le régime de TVA et déconnecte" do
    browser = signed_in
    S.connect
    browser.post("/ext/SUPERPDP/check").status.should eq(302)
    browser.get("/ext/SUPERPDP/").html.should contain("SUPER PDP répond (Bac à sable).")
    browser.post("/ext/SUPERPDP/vat-regime", {"vat_regime" => "quarterly"}).status.should eq(302)
    html = browser.get("/ext/SUPERPDP/").html
    html.should contain("Régime de TVA enregistré chez SUPER PDP.")
    html.should contain(%(<option value="quarterly" selected>))
    browser.post("/ext/SUPERPDP/disconnect").status.should eq(302)
    html = browser.get("/ext/SUPERPDP/").html
    html.should contain("SUPER PDP est déconnecté ; les jetons sont révoqués.")
    html.should contain("SUPER PDP n'est pas raccordé")
    S.platform.revoked.size.should eq(1)
  end
end
