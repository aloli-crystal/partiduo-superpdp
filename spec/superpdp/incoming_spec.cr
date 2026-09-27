# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Superpdp::SpecSupport
private alias E = Einvoicing::SpecSupport
private alias EApi = Einvoicing::Api

private def ready : Nil
  S.books
  S.connect
end

private def sync : EApi::SyncView
  EApi.synchronize(E.admin).value!
end

private def delivered(count : Int32) : Array(Superpdp::SpecSupport::SimulatedSuperpdp::Invoice)
  (1..count).map do |index|
    S.platform.deliver(S.supplier_company, S.company, E.ubl_invoice(number: "FM-2026-04#{index}#{index}"))
  end
end

private def cursor : String?
  Einvoicing::Connection.filter(adapter: "SUPERPDP").first!.incoming_cursor
end

describe "Réception par SUPER PDP : factures et statuts par curseur (ADR-004 D2, D8)" do
  it "reçoit par GET /invoices?direction=in avec starting_after_id, page après page jusqu'à has_after = false" do
    ready
    invoices = delivered(5)
    S.platform.max_page = 2
    sync.received.should eq(5)
    EApi.receptions(E.admin).map(&.number).sort!.should eq(%w[FM-2026-0411 FM-2026-0422 FM-2026-0433 FM-2026-0444 FM-2026-0455])
    cursor.should eq(invoices.last.twin_id.to_s)
    lists = S.platform.api_requests("/invoices", "GET").map { |request| URI.parse(request.url).query_params }
    lists.map { |params| {params["direction"]?, params["starting_after_id"]?} }.first(3)
      .should eq([{"in", nil}, {"in", invoices[1].twin_id.to_s}, {"in", invoices[3].twin_id.to_s}])
    # Rien de nouveau : une seule page, rien n'est relu.
    sync.received.should eq(0)
    URI.parse(S.platform.api_requests("/invoices", "GET").last.url).query_params["starting_after_id"]
      .should eq(invoices.last.twin_id.to_s)
    more = delivered(1).first
    sync.received.should eq(1)
    cursor.should eq(more.twin_id.to_s)
  end

  it "télécharge le fichier original (format=original) et le dépose dans la boîte « Justificatifs à traiter »" do
    ready
    E.supplier
    delivered(1)
    sync
    view = EApi.receptions(E.admin).first
    {view.status, view.supplier_siren, view.adapter}.should eq({"received", E::SUPPLIER_SIREN, "SUPERPDP"})
    view.platform_ref.should eq(S.platform.invoices_of(S.company, "in").first.id.to_s)
    request = S.platform.api_requests("/invoices/#{view.platform_ref}", "GET").first
    URI.parse(request.url).query_params["format"].should eq("original")
    EApi.reception_file(E.admin, view.id).filename.should eq("superpdp-#{view.platform_ref}.xml")
  end

  it "refuse une facture reçue : fr:210 émis avec son motif et sa note ; le fournisseur le voit" do
    ready
    sent = delivered(1).first
    sync
    view = EApi.receptions(E.admin).first
    EApi.refuse(E.admin, view.id, EApi::RefuseInput.new("DOUBLON", "Déjà reçue en juillet")).value!
    event = EApi.reception_events(E.admin, view.id).find! { |item| item.code == "210" }
    event.state.should eq("sent")
    body = JSON.parse(String.new(S.platform.api_requests("/invoice_events", "POST").first.body || Bytes.empty))
    {body["invoice_id"].as_i64, body["status_code"].as_s}.should eq({view.platform_ref.to_i64, "fr:210"})
    body["details"][0]["reason"].should eq("DOUBLON")
    body["details"][0]["notes"][0]["contents"][0]["content"].should eq("Déjà reçue en juillet")
    S.platform.events_of(sent).map(&.status_code).should contain("fr:210")
    # Le statut émis n'est pas relu comme un statut reçu.
    sync.statuses.should eq(0)
    EApi.reception_events(E.admin, view.id).count(&.code.==("210")).should eq(1)
  end

  it "applique les statuts du fournisseur sur une facture reçue : Encaissée (212) avec son montant" do
    ready
    sent = delivered(1).first
    sync
    view = EApi.receptions(E.admin).first
    S.platform.emit(S.supplier_company, sent, "fr:212", [{"reported_data" => [
      {"type_code" => "MEN", "amount" => "200.00", "currency_code" => "EUR", "value_percent" => "20.00", "date" => "2026-09-25"},
      {"type_code" => "MEN", "amount" => "100.00", "currency_code" => "EUR", "value_percent" => "20.00", "date" => "2026-09-25"},
    ]}])
    sync.statuses.should eq(1)
    event = EApi.reception_events(E.admin, view.id).find! { |item| item.code == "212" }
    {event.issuer, event.amount, event.state}.should eq({"seller", E.d("300"), "received"})
  end

  it "lit le sens d'une facture inconnue du dossier auprès de l'API, une seule fois" do
    ready
    other = S.platform.add_company("Autre SAS", "404833048", ["0225:404833048"])
    # Facture déposée par le dossier hors de Partiduo (interface SUPER PDP).
    S.platform.deliver(S.company, other, E.cii_invoice)
    sync.statuses.should eq(0) # inconnue d'EINV : ignorée
    Superpdp::InvoiceRef.filter(direction: "out").count.should eq(1)
    lookups = S.platform.requests.count { |request| URI.parse(request.url).path.matches?(%r{/v1.beta/invoices/\d+\z}) }
    lookups.should eq(1)
  end

  it "suit les statuts sur le curseur des événements (starting_after_id), sans doublon" do
    ready
    delivered(3)
    S.platform.max_page = 2
    sync
    stored = Einvoicing::Connection.filter(adapter: "SUPERPDP").first!.status_cursor
    stored.should eq(S.platform.events.select { |item| item.company_id == S.company.id }.max_of(&.id).to_s)
    count = Einvoicing::Event.count
    sync
    Einvoicing::Event.count.should eq(count)
  end
end
