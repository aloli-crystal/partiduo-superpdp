# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Superpdp::SpecSupport
private alias E = Einvoicing::SpecSupport
private alias EApi = Einvoicing::Api
private alias Connector = Einvoicing::Connector

private def sync : EApi::SyncView
  EApi.synchronize(E.admin).value!
end

private def foreign_sale : Nil
  foreign = E.card("CUSTOMER", "Müller GmbH", "CLI-MULLER", vat: "DE129273398", country: "DE", email: "rechnung@mueller.test")
  E.issue(foreign)
end

describe "E-reporting par SUPER PDP (ADR-004 D8)" do
  it "déclare les ventes internationales par b2bint_invoices, une fois le régime de TVA choisi" do
    S.books
    S.connect
    foreign_sale
    result = sync
    result.reports.should eq(0)
    result.errors.first.should contain("VAT regime")
    Einvoicing::Report.first!.state.should eq("failed")
    Superpdp::SentMessage.count.should eq(0)

    status = Superpdp::Api.update_vat_regime(S.admin, Superpdp::Api::VatRegimeInput.new("monthly")).value!
    status.vat_regime.should eq("monthly")
    S.company.vat_regime.should eq("monthly")
    Superpdp::Api.update_vat_regime(S.admin, Superpdp::Api::VatRegimeInput.new("annuel"))
      .errors.map(&.key).should eq(["superpdp.errors.vat_regime.invalid"])
    sync.reports.should eq(1)
    item = S.platform.b2bint.first
    {item["direction"], item["number"], item["issue_date"], item["type_code"]}
      .should eq({"out", Einvoicing::Transmission.first!.number, "2026-09-10", "380"})
    item["seller"].as_h.should eq({"country" => "FR", "company_id" => E::COMPANY_SIREN, "company_id_scheme_id" => "0002",
                                   "tax_registration_id" => "FR44732829320", "tax_registration_id_qualifying_id" => "VA"})
    item["buyer"].as_h.should eq({"country" => "DE", "tax_registration_id" => "DE129273398", "tax_registration_id_qualifying_id" => "VA"})
    item["tax_subtotals"][0]["tax_category"].as_h.should eq({"code" => "S", "percent" => "20.00"})
    item["total"]["tax_exclusive_amount"].should eq("800.00")
    Einvoicing::Report.first!.state.should eq("sent")
    sync.reports.should eq(0)
    S.platform.b2bint.size.should eq(1)
  end

  it "reprend un envoi d'e-reporting dont la réponse s'est perdue sans déclarer deux fois" do
    S.books
    S.connect
    S.company.vat_regime = "quarterly"
    foreign_sale
    S.platform.lose_next = "POST /b2bint_invoices"
    sync.reports.should eq(0)
    Superpdp::SentMessage.first!.state.should eq("pending")
    sync.reports.should eq(1)
    S.platform.b2bint.size.should eq(1)
    Superpdp::SentMessage.first!.state.should eq("sent")
  end

  it "prépare les transactions et encaissements B2C déclarés sans facture" do
    entry = Connector::EReportingEntry.new(invoice_number: "Z-2026-09-27", date: E.date("2026-09-27"), type_code: "380",
      currency_code: "EUR", net: E.d("15.00"), vat: E.d("3.00"), gross: E.d("18.00"), counterpart_country: "FR",
      category: "services")
    transaction = Superpdp::Mapping.b2c_transaction(entry)
    {transaction["category_code"], transaction["date"], transaction["tax_total"], transaction["role_code"]}
      .should eq({"TPS1", "2026-09-27", "3.00", "SE"})
    transaction["tax_subtotals"][0]["tax_percent"].should eq("20.00")
    payment = Superpdp::Mapping.b2c_payment(entry)
    payment["subtotals"][0]["amount"].should eq("18.00")
    expect_raises(Einvoicing::Unsupported) do
      S.books
      S.connect
      S.connector.send_ereporting(Connector::EReportingBatch.new(kind: "inconnu", period_start: E.date("2026-09-01"),
        period_end: E.date("2026-09-30"), declarant: Connector::Party.new(name: "x"), entries: [entry], tracking_id: "t"))
    end
  end
end
