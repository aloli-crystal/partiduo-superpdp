# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Superpdp::SpecSupport
private alias E = Einvoicing::SpecSupport
private alias EApi = Einvoicing::Api
private alias Inv = Partiduo::Api::Invoicing

private def ready : Nil
  S.books
  S.connect
  S.customer_company
end

private def sync : EApi::SyncView
  EApi.synchronize(E.admin).value!
end

private def posted_invoices : Array(Einvoicing::Http::Request)
  S.platform.api_requests("/invoices", "POST")
end

describe "Émission par SUPER PDP : dépôt, statuts, reprises (ADR-004 D8)" do
  it "dépose le PDF/A-3 Factur-X de la Facturation avec external_id et processing_rule ; la facture arrive chez le client" do
    ready
    invoice = E.issue
    result = sync
    {result.transmitted, result.errors}.should eq({1, [] of String})
    request = posted_invoices.first
    request.headers["Content-Type"].should eq("application/pdf")
    request.body.should eq(Inv.document_pdf(E::SYSTEM, invoice.id).content)
    params = URI.parse(request.url).query_params
    row = E.transmission(invoice)
    params["external_id"].should eq(row.tracking_id.lchop("PDUO-"))
    params["processing_rule"].should eq("B2B")
    sent = S.platform.invoices_of(S.company, "out").first
    {row.status, row.adapter, row.syntax, row.platform_ref}.should eq({"deposited", "SUPERPDP", "Factur-X", sent.id.to_s})
    # Chez le client (Atelier Morel), la facture est reçue.
    S.platform.invoices_of(S.customer_company, "in").size.should eq(1)
    codes = EApi.transmission_events(E.admin, row.id).map(&.code)
    codes.should eq(%w[200 201 202])
    Inv.document(E::SYSTEM, invoice.id).sent_at.should_not be_nil
    # Rien n'est relu deux fois.
    sync.statuses.should eq(0)
  end

  it "remonte « Rejetée » (213) avec son motif, puis retransmet après correction" do
    ready
    invoice = E.issue
    S.platform.reject_next = "Montant total incohérent"
    sync
    row = E.transmission(invoice)
    {row.status, row.last_code}.should eq({"rejected", "213"})
    row.error.should contain("Montant total incohérent")
    # Même fichier retransmis : la plateforme le connaît déjà, rejeté ; rien
    # n'est déposé deux fois.
    EApi.transmit(E.admin, row.id).success?.should be_true
    {E.transmission(invoice).status, posted_invoices.size}.should eq({"rejected", 1})
  end

  it "rend « Rejetée » un dépôt refusé au contrôle (400) sans le garder en attente" do
    ready
    invoice = E.issue
    # La plateforme a déjà ce fichier sous un autre external_id : refus 400.
    S.platform.deliver(S.company, S.customer_company, Inv.document_pdf(E::SYSTEM, invoice.id).content, "application/pdf")
    sync.transmitted.should eq(1)
    row = E.transmission(invoice)
    {row.status, row.last_code}.should eq({"rejected", "213"})
    row.error.should contain("Fichier déjà chargé")
    Superpdp::InvoiceRef.filter(state: "pending").count.should eq(0)
  end

  it "signale une adresse de destinataire introuvable (api:invalid)" do
    S.books
    S.connect
    invoice = E.issue # client absent de l'annuaire simulé
    sync
    row = E.transmission(invoice)
    {row.status, row.last_code}.should eq({"rejected", "213"})
    row.error.should contain("DEST_INC")
  end

  it "reprend un dépôt dont la réponse s'est perdue sans déposer deux fois (idempotence)" do
    ready
    invoice = E.issue
    S.platform.lose_next = "POST /invoices"
    result = sync
    result.transmitted.should eq(0)
    result.errors.first.should contain("injoignable")
    E.transmission(invoice).status.should eq("pending")
    Superpdp::InvoiceRef.filter(direction: "out").first!.state.should eq("pending")
    S.platform.invoices_of(S.company, "out").size.should eq(1)
    sync.transmitted.should eq(1)
    S.platform.invoices_of(S.company, "out").size.should eq(1)
    posted_invoices.size.should eq(1)
    row = E.transmission(invoice)
    {row.status, row.platform_ref}.should eq({"deposited", S.platform.invoices_of(S.company, "out").first.id.to_s})
  end

  it "rejoue une requête refusée pour surcharge (429, 503) ; une panne (500) laisse la facture à transmettre" do
    ready
    invoice = E.issue
    S.platform.fail_next(429, 503)
    sync.transmitted.should eq(1)
    E.transmission(invoice).status.should eq("deposited")
    other = E.issue(quantity: "3")
    S.platform.fail_next(500)
    result = sync
    # Erreur traduite à la lecture (D-EINV-024) : numéro de la facture, texte brut de SUPER PDP.
    result.errors.first.should eq("Facture #{other.number} : SUPER PDP a répondu 500 : service unavailable")
    I18n.with_locale("en") { E.transmission(other).error.should eq("SUPER PDP answered 500: service unavailable") }
    E.transmission(other).status.should eq("pending")
    sync.transmitted.should eq(1)
    E.transmission(other).status.should eq("deposited")
  end

  it "transmet une vente B2C en CII avec la note BAR et la règle B2C" do
    ready
    customer = E.card("CUSTOMER", "Jeanne Dupuis", "CLI-DUPUIS", email: "jeanne@exemple.test")
    invoice = E.issue(customer)
    sync.transmitted.should eq(1)
    request = posted_invoices.first
    request.headers["Content-Type"].should eq("application/xml")
    URI.parse(request.url).query_params["processing_rule"].should eq("B2C")
    String.new(request.body || Bytes.empty).should contain("<ram:SubjectCode>BAR</ram:SubjectCode>")
    E.transmission(invoice).status.should eq("deposited")
  end

  it "émet « Encaissée » (212) ventilée par taux (règle BR-FR-CDV-14), une seule fois, sans la relire comme reçue" do
    ready
    invoice = E.issue
    sync
    row = E.transmission(invoice)
    Partiduo::Api::Transaction.run do
      Partiduo::Events.publish("payment.matched", {"matching_id" => "77", "sources" => "invoice:#{invoice.id}",
                                                   "amounts" => "invoice:#{invoice.id}=500.00", "matched_on" => "2026-09-20"})
      Partiduo::Api::Result(Nil).success(nil)
    end
    event = EApi.transmission_events(E.admin, row.id).find! { |item| item.code == "212" }
    {event.state, event.amount}.should eq({"sent", E.d("500")})
    request = S.platform.api_requests("/invoice_events", "POST").first
    body = JSON.parse(String.new(request.body || Bytes.empty))
    body["status_code"].should eq("fr:212")
    body["invoice_id"].as_i64.should eq(row.platform_ref.to_s.to_i64)
    data = body["details"][0]["reported_data"].as_a
    data.map { |item| {item["type_code"].as_s, item["amount"].as_s, item["value_percent"].as_s, item["date"].as_s} }
      .should eq([{"MEN", "500.00", "20.00", "2026-09-20"}])
    # Le client voit « Encaissée » ; le dossier ne la relit pas comme un statut reçu.
    customer_invoice = S.platform.invoices_of(S.customer_company, "in").first
    S.platform.events_of(customer_invoice).map(&.status_code).should contain("fr:212")
    sync.statuses.should eq(0)
    EApi.transmission_events(E.admin, row.id).count(&.code.==("212")).should eq(1)
    S.platform.api_requests("/invoice_events", "POST").size.should eq(1)
  end

  it "ventile un encaissement partiel au prorata des taux, l'écart d'arrondi sur le dernier" do
    breakdown = JSON.parse(<<-JSON).as_a
      [{"vat_category_taxable_amount": "60.46", "vat_category_tax_amount": "3.33", "vat_category_rate": "5.50"},
       {"vat_category_taxable_amount": "1500.00", "vat_category_tax_amount": "300.00", "vat_category_rate": "20.00"}]
      JSON
    full = Superpdp::Mapping.payment_data(breakdown, nil, "EUR", E.date("2026-09-27"))
    full.map { |item| {item["amount"], item["value_percent"]} }.should eq([{"63.79", "5.50"}, {"1800.00", "20.00"}])
    part = Superpdp::Mapping.payment_data(breakdown, E.d("1000.00"), "EUR", E.date("2026-09-27"))
    part.map { |item| item["amount"] }.should eq(["34.23", "965.77"])
    part.sum { |item| E.d(item["amount"]) }.should eq(E.d("1000.00"))
  end

  it "reprend un statut émis dont la réponse s'est perdue sans l'émettre deux fois" do
    ready
    invoice = E.issue
    sync
    S.platform.lose_next = "POST /invoice_events"
    Partiduo::Events.publish("payment.recorded", {"payment_id" => "5", "invoice_id" => invoice.id.to_s, "amount" => "960.00",
                                                  "paid_on" => "2026-09-21"})
    Einvoicing::Event.filter(code: "212").first!.state.should eq("failed")
    sync.sent_statuses.should eq(1)
    Einvoicing::Event.filter(code: "212").first!.state.should eq("sent")
    S.platform.api_requests("/invoice_events", "POST").size.should eq(1)
    S.platform.events.count { |item| item.status_code == "fr:212" && item.company_id == S.company.id }.should eq(1)
  end

  it "applique les statuts du client : Approuvée (205), Refusée (210) avec son motif" do
    ready
    invoice = E.issue
    sync
    customer_invoice = S.platform.invoices_of(S.customer_company, "in").first
    S.platform.emit(S.customer_company, customer_invoice, "fr:205")
    sync.statuses.should eq(1)
    E.transmission(invoice).status.should eq("approved")
    S.platform.emit(S.customer_company, customer_invoice, "fr:210",
      [{"reason" => "TX_TVA_ERR", "notes" => [{"contents" => [{"content" => "Taux de TVA erroné"}]}]}])
    sync.statuses.should eq(1)
    row = E.transmission(invoice)
    row.status.should eq("refused")
    event = EApi.transmission_events(E.admin, row.id).find! { |item| item.code == "210" }
    {event.issuer, event.reason_code, event.reason}.should eq({"buyer", "TX_TVA_ERR", "Taux de TVA erroné"})
  end

  it "transmet à un client belge en UBL PEPPOL BIS, adresse 0208 (Belgique par Peppol)" do
    S.books("be")
    S.connect(S.platform.add_company("Atelier Dupont SRL", "0417497106", ["0208:0417497106"], scheme: "be_numero_entreprise", country: "BE"))
    client = S.platform.add_company("Infrabel", "0869763267", ["0208:0869763267"], scheme: "be_numero_entreprise", country: "BE")
    customer = E.card("CUSTOMER", "Infrabel SA", "CLI-INFRABEL", vat: "BE0869763267", country: "BE", email: "factures@infrabel.test")
    invoice = E.issue(customer, channel: "platform")
    sync.transmitted.should eq(1)
    request = posted_invoices.first
    request.headers["Content-Type"].should eq("application/xml")
    xml = String.new(request.body || Bytes.empty)
    xml.should contain("urn:fdc:peppol.eu:2017:poacc:billing:01:1.0")
    xml.should contain(%(<cbc:EndpointID schemeID="0208">0869763267</cbc:EndpointID>))
    S.platform.invoices_of(client, "in").size.should eq(1)
    E.transmission(invoice).status.should eq("deposited")
  end
end
