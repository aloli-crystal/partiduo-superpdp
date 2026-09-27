# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Superpdp::SpecSupport

private def connected : Superpdp::Connector
  S.books
  S.connect
  S.connector
end

describe "Erreurs de l'API SUPER PDP (page « Erreurs »)" do
  it "lit la réponse http_ko : code HTTP et message, sans l'interpréter" do
    connector = connected
    error = expect_raises(Superpdp::ApiError) { connector.client.get_json("/invoices/42") }
    {error.status, error.api_message}.should eq({404, ""})
    error = expect_raises(Superpdp::ApiError) do
      connector.client.get_json("/invoices", URI::Params{"starting_after_id" => "abc"})
    end
    {error.status, error.api_message, error.server?}.should eq({400, "invalid pagination", false})
    S.platform.fail_next(500)
    error = expect_raises(Superpdp::ApiError) { connector.company }
    {error.status, error.server?}.should eq({500, true})
    error.message.should eq("SUPER PDP 500 : service unavailable")
  end

  it "rejoue après un délai une requête refusée pour surcharge (429, 503), puis abandonne" do
    connector = connected
    S.platform.fail_next(429, 503)
    connector.company["formal_name"].should eq("Atelier Brunet SARL")
    S.platform.fail_next(503, 503, 503)
    expect_raises(Superpdp::ApiError, "SUPER PDP 503") { connector.company }
  end

  it "rejoue une lecture après une coupure réseau, jamais une écriture" do
    connector = connected
    S.platform.lose_next = "GET /companies/me"
    connector.company["formal_name"].should eq("Atelier Brunet SARL")
    S.platform.lose_next = "PATCH /companies"
    expect_raises(Einvoicing::ConnectorError, "injoignable") { connector.update_vat_regime("monthly", false) }
    S.platform.api_requests("/companies", "PATCH").size.should eq(1)
  end

  it "demande de se raccorder de nouveau quand l'accès reste refusé (401)" do
    connector = connected
    S.company.client_secret = "change"
    S.platform.expire_access_tokens!
    expect_raises(Superpdp::AuthorizationRequired) { connector.company }
    Superpdp::Api.check(S.admin).errors.map(&.key).should eq(["superpdp.errors.connection.authorization"])
  end

  it "refuse une adresse non HTTPS sur le réseau réel (TLS vérifié par EINV)" do
    Einvoicing::Http.transport = nil
    expect_raises(Einvoicing::ConnectorError, "non HTTPS") { Einvoicing::Http.exec("GET", "http://api.superpdp.tech/v1.beta/companies/me") }
  end
end
