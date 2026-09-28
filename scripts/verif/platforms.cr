# SPDX-License-Identifier: AGPL-3.0-or-later

# Plateformes agréées simulées des specs (ADR-004 D6), branchées ici sur une
# instance réelle : SUPER PDP simulée (`spec/support/superpdp_platform.cr`)
# et plateforme XP Z12-013 simulée d'EINV (`spec/support/platform.cr`).
require "../../spec/support/superpdp_platform"
require "../../lib/partiduo-einvoicing/spec/support/platform"
require "../../spec/support/proxy_transport"

module Verif
  # Plateforme XP Z12-013 simulée qui, comme une vraie plateforme, contrôle
  # d'elle-même chaque flux déposé : accusé `Ok` (« Déposée ») à la lecture
  # suivante des flux.
  class AutoAckPlatform < Einvoicing::SpecSupport::SimulatedPlatform
    def exec(request : Request) : Response
      if request.url.includes?("/flows/search")
        flows.each { |flow| acknowledge(flow, "Ok") if flow.direction == "Out" && flow.ack == "Pending" }
      end
      super
    end
  end

  # SIREN (clé de Luhn valide) des parties simulées.
  COMPANY_SIREN  = "732829320"
  CUSTOMER_SIREN = "552100554"
  SUPPLIER_SIREN = "542107651"

  # Facture UBL d'un fournisseur adressée au dossier (`COMPANY_SIREN`).
  def self.ubl_invoice(number : String, net : String, vat : String, gross : String, siren : String = SUPPLIER_SIREN,
                       name : String = "Fournitures Martin SAS", day : String = "2026-09-05") : Bytes
    <<-XML.to_slice
      <?xml version="1.0" encoding="UTF-8"?>
      <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2" xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
        <cbc:CustomizationID>urn:cen.eu:en16931:2017</cbc:CustomizationID>
        <cbc:ID>#{number}</cbc:ID>
        <cbc:IssueDate>#{day}</cbc:IssueDate>
        <cbc:DueDate>2026-10-31</cbc:DueDate>
        <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
        <cbc:Note>Fournitures de bureau</cbc:Note>
        <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
        <cac:AccountingSupplierParty><cac:Party>
          <cbc:EndpointID schemeID="0225">#{siren}</cbc:EndpointID>
          <cac:PartyName><cbc:Name>#{name}</cbc:Name></cac:PartyName>
          <cac:PostalAddress><cbc:CityName>Lyon</cbc:CityName><cbc:PostalZone>69002</cbc:PostalZone><cac:Country><cbc:IdentificationCode>FR</cbc:IdentificationCode></cac:Country></cac:PostalAddress>
          <cac:PartyTaxScheme><cbc:CompanyID>FR83#{siren}</cbc:CompanyID><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:PartyTaxScheme>
          <cac:PartyLegalEntity><cbc:RegistrationName>#{name}</cbc:RegistrationName><cbc:CompanyID schemeID="0002">#{siren}</cbc:CompanyID></cac:PartyLegalEntity>
        </cac:Party></cac:AccountingSupplierParty>
        <cac:AccountingCustomerParty><cac:Party>
          <cbc:EndpointID schemeID="0225">#{COMPANY_SIREN}</cbc:EndpointID>
          <cac:PartyName><cbc:Name>Atelier Brunet SARL</cbc:Name></cac:PartyName>
          <cac:PostalAddress><cac:Country><cbc:IdentificationCode>FR</cbc:IdentificationCode></cac:Country></cac:PostalAddress>
          <cac:PartyLegalEntity><cbc:RegistrationName>Atelier Brunet SARL</cbc:RegistrationName><cbc:CompanyID schemeID="0002">#{COMPANY_SIREN}</cbc:CompanyID></cac:PartyLegalEntity>
        </cac:Party></cac:AccountingCustomerParty>
        <cac:TaxTotal>
          <cbc:TaxAmount currencyID="EUR">#{vat}</cbc:TaxAmount>
          <cac:TaxSubtotal><cbc:TaxableAmount currencyID="EUR">#{net}</cbc:TaxableAmount><cbc:TaxAmount currencyID="EUR">#{vat}</cbc:TaxAmount>
            <cac:TaxCategory><cbc:ID>S</cbc:ID><cbc:Percent>20.00</cbc:Percent><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:TaxCategory></cac:TaxSubtotal>
        </cac:TaxTotal>
        <cac:LegalMonetaryTotal>
          <cbc:LineExtensionAmount currencyID="EUR">#{net}</cbc:LineExtensionAmount>
          <cbc:TaxExclusiveAmount currencyID="EUR">#{net}</cbc:TaxExclusiveAmount>
          <cbc:TaxInclusiveAmount currencyID="EUR">#{gross}</cbc:TaxInclusiveAmount>
          <cbc:PayableAmount currencyID="EUR">#{gross}</cbc:PayableAmount>
        </cac:LegalMonetaryTotal>
        <cac:InvoiceLine>
          <cbc:ID>1</cbc:ID>
          <cbc:InvoicedQuantity unitCode="C62">1</cbc:InvoicedQuantity>
          <cbc:LineExtensionAmount currencyID="EUR">#{net}</cbc:LineExtensionAmount>
          <cac:Item><cbc:Name>Ramettes de papier</cbc:Name><cac:ClassifiedTaxCategory><cbc:ID>S</cbc:ID><cbc:Percent>20.00</cbc:Percent><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:ClassifiedTaxCategory></cac:Item>
          <cac:Price><cbc:PriceAmount currencyID="EUR">#{net}</cbc:PriceAmount></cac:Price>
        </cac:InvoiceLine>
      </Invoice>
      XML
  end

  # Vrai bac à sable SUPER PDP : identifiants des deux entreprises fictives,
  # lus comme la suite d'intégration (`spec/integration/sandbox_spec.cr`),
  # jamais affichés.
  module Sandbox
    VARS = %w[SUPERPDP_SANDBOX_SELLER_CLIENT_ID SUPERPDP_SANDBOX_SELLER_CLIENT_SECRET
      SUPERPDP_SANDBOX_BUYER_CLIENT_ID SUPERPDP_SANDBOX_BUYER_CLIENT_SECRET]
    FILE = Path.home.join(".config", "partiduo", "superpdp-sandbox.env").to_s

    def self.credentials : Hash(String, String)?
      values = {} of String => String
      if File.exists?(FILE)
        File.each_line(FILE) do |line|
          name, separator, value = line.strip.partition('=')
          next if separator.empty? || name.starts_with?('#')
          value = value.sub(/\s+#.*\z/, "").strip
          value = value[1..-2] if value.size >= 2 && value[0] == value[-1] && value[0].in?('"', '\'')
          values[name.strip.lchop("export ").strip] = value
        end
      end
      VARS.each { |name| ENV[name]?.presence.try { |value| values[name] = value } }
      VARS.all? { |name| values[name]?.presence } ? values : nil
    end

    def self.connector(values : Hash(String, String), role : String) : Superpdp::Connector
      credentials = Superpdp::Credentials.new(values["SUPERPDP_SANDBOX_#{role}_CLIENT_ID"],
        values["SUPERPDP_SANDBOX_#{role}_CLIENT_SECRET"], Superpdp::CLIENT_CREDENTIALS)
      Superpdp::Connector.new(Superpdp::Client.new(credentials, Superpdp::MemoryStore.new))
    end

    # Facture de test SUPER PDP (CII) du vendeur `seller`, adressée à
    # `buyer_address` (adresse 0225), au numéro donné.
    def self.invoice(seller : Superpdp::Connector, buyer_address : String, number : String) : Bytes
      xml, _ = seller.client.get_bytes("/invoices/generate_test_invoice", URI::Params{"format" => "cii"}, "application/xml")
      text = String.new(xml)
      text = text.sub(%r{(<ExchangedDocument[^>]*>\s*<ID[^>]*>)[^<]+(</ID>)}) { "#{$1}#{number}#{$2}" }
      text = text.sub(%r{(<BuyerTradeParty[^>]*>.*?<URIID[^>]*schemeID="0225"[^>]*>)[^<]+(</URIID>)}m) { "#{$1}#{buyer_address}#{$2}" }
      text.to_slice
    end

    def self.outgoing(number : String, content : Bytes) : Einvoicing::Connector::OutgoingInvoice
      party = Einvoicing::Connector::Party.new(name: "Atelier Brunet SARL", country_code: "FR")
      Einvoicing::Connector::OutgoingInvoice.new(invoice_id: 0_i64, number: number, type_code: "380", syntax: "CII",
        profile: "EN16931", filename: "#{number}.xml", content_type: "application/xml", content: content,
        processing_rule: "B2B", seller: Einvoicing::Connector::Party.new(name: "Acheteur fictif", country_code: "FR"),
        buyer: party, tracking_id: "PDUO-#{UUID.random}", sha256: Digest::SHA256.hexdigest(content))
    end

    # Adresse électronique (0225) de l'entreprise du connecteur.
    def self.address(connector : Superpdp::Connector) : String
      line = connector.directory_entries.find { |item| !(item["is_replyto"]?.try(&.as_bool?) || false) } ||
             raise "entreprise fictive sans ligne d'annuaire"
      line["identifier"].as_s.lchop("0225:")
    end
  end
end
