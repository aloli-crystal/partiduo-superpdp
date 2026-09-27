# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Suite d'intégration contre le *vrai* bac à sable SUPER PDP (ADR-004 D8),
# activée seulement si les identifiants des deux entreprises fictives
# existent : variables `SUPERPDP_SANDBOX_SELLER_CLIENT_ID`,
# `SUPERPDP_SANDBOX_SELLER_CLIENT_SECRET` (émettrice),
# `SUPERPDP_SANDBOX_BUYER_CLIENT_ID`, `SUPERPDP_SANDBOX_BUYER_CLIENT_SECRET`
# (destinataire), lues dans l'environnement ou, à défaut, dans
# `~/.config/partiduo/superpdp-sandbox.env` (lignes `VAR=valeur`, lues
# comme le shell : commentaire final, guillemets).
# `SUPERPDP_SANDBOX=off` la désactive.
#
# Les secrets ne sont jamais affichés ni journalisés : les jetons restent en
# mémoire (`Superpdp::MemoryStore`), les messages d'échec ne citent que des
# identifiants de factures et des codes de statut.
module Superpdp
  module SpecSupport
    module Sandbox
      VARS = %w[SUPERPDP_SANDBOX_SELLER_CLIENT_ID SUPERPDP_SANDBOX_SELLER_CLIENT_SECRET
        SUPERPDP_SANDBOX_BUYER_CLIENT_ID SUPERPDP_SANDBOX_BUYER_CLIENT_SECRET]
      FILE = Path.home.join(".config", "partiduo", "superpdp-sandbox.env").to_s

      # Délai d'attente du traitement asynchrone de la plateforme.
      TIMEOUT = 90.seconds

      def self.credentials : Hash(String, String)?
        return if ENV["SUPERPDP_SANDBOX"]? == "off"
        values = {} of String => String
        if File.exists?(FILE)
          File.each_line(FILE) do |line|
            name, separator, value = line.strip.partition('=')
            next if separator.empty? || name.starts_with?('#')
            # Comme le shell : commentaire en fin de ligne après une espace,
            # guillemets autour de la valeur.
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

      # Dernier identifiant de facture reçue (curseur de départ).
      def self.last_incoming(connector : Superpdp::Connector) : Einvoicing::Connector::Cursor?
        params = URI::Params{"direction" => "in", "order" => "desc", "limit" => "1"}
        connector.client.get_json("/invoices", params)["data"].as_a.first?.try { |item| Einvoicing::Connector::Cursor.new(item["id"].as_i64.to_s) }
      end

      # Dernier identifiant d'événement (curseur de départ), page après page.
      def self.last_event(connector : Superpdp::Connector) : Einvoicing::Connector::Cursor?
        cursor = nil
        loop do
          params = URI::Params{"limit" => "1000"}
          cursor.try { |value| params["starting_after_id"] = value.value }
          json = connector.client.get_json("/invoice_events", params)
          data = json["data"].as_a
          data.last?.try { |item| cursor = Einvoicing::Connector::Cursor.new(item["id"].as_i64.to_s) }
          break unless json["has_after"].as_bool
        end
        cursor
      end

      # Attend, en lisant par curseur, que `found` rende un résultat.
      def self.poll(what : String, &) : Nil
        deadline = Time.instant + TIMEOUT
        loop do
          return if yield
          raise "délai dépassé en attendant : #{what}" if Time.instant > deadline
          sleep 2.seconds
        end
      end

      # Facture de test SUPER PDP (CII) adressée à l'acheteur : numéro
      # unique, adresse électronique de l'acheteur.
      def self.invoice(seller : Superpdp::Connector, buyer_address : String, number : String) : Bytes
        xml, _ = seller.client.get_bytes("/invoices/generate_test_invoice", URI::Params{"format" => "cii"}, "application/xml")
        text = String.new(xml)
        text = text.sub(%r{(<ExchangedDocument[^>]*>\s*<ID[^>]*>)[^<]+(</ID>)}) { "#{$1}#{number}#{$2}" }
        text = text.sub(%r{(<BuyerTradeParty[^>]*>.*?<URIID[^>]*schemeID="0225"[^>]*>)[^<]+(</URIID>)}m) { "#{$1}#{buyer_address}#{$2}" }
        text.to_slice
      end

      def self.outgoing(number : String, content : Bytes) : Einvoicing::Connector::OutgoingInvoice
        party = Einvoicing::Connector::Party.new(name: "Tricatel", country_code: "FR")
        Einvoicing::Connector::OutgoingInvoice.new(invoice_id: 0_i64, number: number, type_code: "380", syntax: "CII",
          profile: "EN16931", filename: "#{number}.xml", content_type: "application/xml", content: content,
          processing_rule: "B2B", seller: Einvoicing::Connector::Party.new(name: "Burger Queen", country_code: "FR"),
          buyer: party, tracking_id: "PDUO-#{UUID.random}", sha256: Digest::SHA256.hexdigest(content))
      end

      def self.buyer_address(buyer : Superpdp::Connector) : String
        line = buyer.directory_entries.find { |item| !(item["is_replyto"]?.try(&.as_bool?) || false) } ||
               raise "l'acheteur fictif n'a pas de ligne d'annuaire"
        line["identifier"].as_s.lchop("0225:")
      end
    end
  end
end

if sandbox = Superpdp::SpecSupport::Sandbox.credentials
  describe "Bac à sable SUPER PDP (intégration réelle, ADR-004 D8)" do
    before_each do
      Einvoicing::Http.transport = Superpdp::SpecSupport::ProxyTransport.from_env
      Superpdp::Config.retry_delays = [1.seconds, 3.seconds]
    end

    after_each do
      Superpdp::SpecSupport.reset_platform
    end

    it "authentifie les deux entreprises fictives : bac à sable, vérifiées, lignes d'annuaire" do
      %w[SELLER BUYER].each do |role|
        connector = Superpdp::SpecSupport::Sandbox.connector(sandbox, role)
        probe = connector.probe
        {probe.verification, probe.env}.should eq({"verified", "sandbox"})
        connector.directory_entries.should_not be_empty
      end
    end

    it "envoie une facture du vendeur à l'acheteur, la reçoit, échange Approuvée (205) et Encaissée (212)" do
      box = Superpdp::SpecSupport::Sandbox
      seller = box.connector(sandbox, "SELLER")
      buyer = box.connector(sandbox, "BUYER")
      incoming_cursor = box.last_incoming(buyer)
      seller_events = box.last_event(seller)
      buyer_events = box.last_event(buyer)
      number = "PDUO-IT-#{Time.utc.to_s("%Y%m%d%H%M%S")}-#{Random::Secure.hex(2)}"
      invoice = box.outgoing(number, box.invoice(seller, box.buyer_address(buyer), number))

      submission = seller.submit(invoice)
      submission.status.should_not eq("error")
      sent_id = submission.platform_ref
      # Reprise idempotente : la même facture n'est pas déposée deux fois.
      seller.submit(invoice).platform_ref.should eq(sent_id)

      # Côté vendeur : Déposée (200) puis Reçue par la plateforme (202).
      seen = [] of Einvoicing::Connector::LifecycleEvent
      box.poll("statuts 200 et 202 de la facture #{sent_id}") do
        loop do
          page = seller.fetch_statuses(seller_events)
          seller_events = page.cursor
          seen.concat(page.items.select { |event| event.invoice_ref == sent_id })
          break unless page.has_more
        end
        codes = seen.map(&.code)
        codes.includes?("200") && codes.includes?("202")
      end
      seen.all? { |event| event.direction == "outgoing" }.should be_true

      # Côté acheteur : la facture arrive par curseur.
      received = nil
      box.poll("réception de la facture #{number}") do
        loop do
          page = buyer.fetch_incoming(incoming_cursor)
          incoming_cursor = page.cursor
          received ||= page.items.find { |item| String.new(item.content).includes?(number) }
          break unless page.has_more
        end
        !received.nil?
      end
      received = received || raise "facture non reçue"
      Einvoicing::Formats::Reader.parse(received.content).number.should eq(number)

      # L'acheteur approuve (205) ; le vendeur le lit sur sa facture.
      buyer.send_status(Einvoicing::Connector::LifecycleEvent.new(code: "205", occurred_at: Time.utc,
        direction: "incoming", invoice_ref: received.platform_ref, issuer: "buyer"))
      approved = nil
      box.poll("Approuvée (205) chez le vendeur") do
        page = seller.fetch_statuses(seller_events)
        seller_events = page.cursor
        approved ||= page.items.find { |event| event.invoice_ref == sent_id && event.code == "205" }
        !approved.nil?
      end
      approved.try(&.issuer).should eq("buyer")

      # Le vendeur émet « Encaissée » (212) pour un encaissement partiel,
      # ventilé par taux ; l'acheteur le lit avec son montant.
      seller.send_status(Einvoicing::Connector::LifecycleEvent.new(code: "212", occurred_at: Time.utc, direction: "outgoing",
        invoice_ref: sent_id, issuer: "seller", amount: BigDecimal.new("100.00")))
      paid = nil
      box.poll("Encaissée (212) chez l'acheteur") do
        page = buyer.fetch_statuses(buyer_events)
        buyer_events = page.cursor
        paid ||= page.items.find { |event| event.invoice_ref == received.platform_ref && event.code == "212" }
        !paid.nil?
      end
      {paid.try(&.issuer), paid.try(&.amount)}.should eq({"seller", BigDecimal.new("100.00")})
      # Le statut émis par le vendeur n'est pas relu comme reçu chez lui.
      page = seller.fetch_statuses(seller_events)
      page.items.none? { |event| event.invoice_ref == sent_id && event.code == "212" }.should be_true
    end

    it "fait refuser une facture par l'acheteur (210) avec son motif, lu par le vendeur" do
      box = Superpdp::SpecSupport::Sandbox
      seller = box.connector(sandbox, "SELLER")
      buyer = box.connector(sandbox, "BUYER")
      incoming_cursor = box.last_incoming(buyer)
      seller_events = box.last_event(seller)
      number = "PDUO-IT-#{Time.utc.to_s("%Y%m%d%H%M%S")}-#{Random::Secure.hex(2)}"
      sent_id = seller.submit(box.outgoing(number, box.invoice(seller, box.buyer_address(buyer), number))).platform_ref
      received = nil
      box.poll("réception de la facture #{number}") do
        page = buyer.fetch_incoming(incoming_cursor)
        incoming_cursor = page.cursor
        received ||= page.items.find { |item| String.new(item.content).includes?(number) }
        !received.nil?
      end
      buyer.send_status(Einvoicing::Connector::LifecycleEvent.new(code: "210", occurred_at: Time.utc, direction: "incoming",
        invoice_ref: (received || raise "facture non reçue").platform_ref, issuer: "buyer", reason_code: "DOUBLON", reason: "Facture déjà reçue (essai Partiduo)"))
      refused = nil
      box.poll("Refusée (210) chez le vendeur") do
        page = seller.fetch_statuses(seller_events)
        seller_events = page.cursor
        refused ||= page.items.find { |event| event.invoice_ref == sent_id && event.code == "210" }
        !refused.nil?
      end
      {refused.try(&.reason_code), refused.try(&.reason)}.should eq({"DOUBLON", "Facture déjà reçue (essai Partiduo)"})
    end

    it "cherche dans l'annuaire français (SIREN de SUPER G)" do
      seller = Superpdp::SpecSupport::Sandbox.connector(sandbox, "SELLER")
      entries = seller.lookup("853322915")
      entries.map(&.address).should contain("853322915")
      entries.first.name.should eq("SUPER G")
    end

    it "fait valider par SUPER PDP une facture Factur-X produite par Partiduo (rapport)" do
      Superpdp::SpecSupport.books
      invoice = Einvoicing::SpecSupport.issue
      pdf = Partiduo::Api::Invoicing.document_pdf(Einvoicing::SpecSupport::SYSTEM, invoice.id)
      report = Superpdp::SpecSupport::Sandbox.connector(sandbox, "SELLER").validate(pdf.filename, pdf.content, "application/pdf")
      subreports = report["subreports"]?.try(&.as_a?) || [] of JSON::Any
      findings = subreports.flat_map do |sub|
        %w[failures messages].flat_map do |kind|
          (sub[kind]?.try(&.as_a?) || [] of JSON::Any).map do |item|
            "#{kind == "failures" ? "échec" : "avertissement"} #{item["rule"]?.try(&.as_s?)} : #{item["message"]?.try(&.as_s?).to_s.lines.first?.to_s.strip}"
          end
        end
      end
      File.write(File.join(Dir.tempdir, "partiduo-superpdp-validation.json"), report.to_pretty_json)
      puts "\n  Validation SUPER PDP du Factur-X de Partiduo : is_valid=#{report["is_valid"]?}, #{findings.size} remarque(s)"
      findings.first(10).each { |finding| puts "    - #{finding}" }
      report["is_valid"]?.should_not be_nil
    end
  end
end
