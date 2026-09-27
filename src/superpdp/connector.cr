# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Adaptateur SUPER PDP de `Einvoicing::Connector` (ADR-004 D8), sur l'API
  # JSON `https://api.superpdp.tech/v1.beta/` :
  #
  # * émission : `POST /invoices` du fichier tel qu'EINV le prépare (PDF/A-3
  #   Factur-X de la Facturation, CII avec la note `BAR` pour le B2C), en
  #   UBL PEPPOL BIS pour un client étranger (Belgique par Peppol) ;
  #   `external_id` et `processing_rule` transmis ; reprise idempotente ;
  # * réception et statuts : `GET /invoices?direction=in` et
  #   `GET /invoice_events` avec `starting_after_id`, page après page
  #   jusqu'à `has_after = false` (curseur = dernier identifiant lu,
  #   ADR-004 D2) ;
  # * statuts émis : `POST /invoice_events` (`fr:210` avec motif,
  #   `fr:212` ventilé par taux…) ;
  # * e-reporting : `b2bint_invoices` (international), `b2c_transactions`
  #   et `b2c_payments` (B2C sans facture) ; le B2B et le B2C facturé sont
  #   déclarés par SUPER PDP à partir des factures et de « Encaissée » ;
  # * annuaire : `french_directory` (adresses `SIREN`, `SIREN_SIRET`,
  #   `SIREN_SUFFIXE`, `SIREN_SIRET_CODEROUTAGE`, schéma `0225`) ; numéro
  #   d'entreprise belge en schéma `0208`.
  #
  # Mode bac à sable ou production : celui de l'entreprise des
  # identifiants (`GET /companies/me`), conservé par `check`.
  class Connector < Einvoicing::Connector
    alias Connections = Einvoicing::Connections

    PAGE_SIZE = 100

    # Pages de factures émises relues pour retrouver un dépôt dont la
    # réponse s'est perdue.
    LOOKBACK_PAGES = 5

    # Paramètres déclarés à EINV : identifiants d'une application SUPER PDP
    # de la société (mode _client credentials_). Laissés vides, le
    # raccordement est en mode _authorization code_ (application de
    # l'opérateur, jeton de rafraîchissement de la société).
    FIELDS = [
      Connections::Field.new("client_id", required: false),
      Connections::Field.new("client_secret", secret: true, required: false),
    ]

    def self.adapter : Connections::Adapter
      Connections::Adapter.new(ADAPTER, "superpdp.adapter", %w[fr be], FIELDS,
        ->(settings : Connections::Settings) { new(settings).as(Einvoicing::Connector) })
    end

    # Identifiants d'un raccordement enregistré.
    def self.credentials(settings : Connections::Settings) : Credentials
      client_id = settings["client_id"]
      if client_id.empty?
        Credentials.new(Config.operator_client_id, Config.operator_client_secret, AUTHORIZATION_CODE)
      else
        Credentials.new(client_id, settings["client_secret"], CLIENT_CREDENTIALS)
      end
    end

    getter client : Client

    def initialize(settings : Connections::Settings)
      @client = Client.new(Connector.credentials(settings), SettingsStore.new(settings))
    end

    def initialize(@client : Client)
    end

    def mode : String
      Account.current.try(&.env).presence || "sandbox"
    end

    def auth_mode : String
      client.credentials.grant
    end

    # Vérifie le raccordement : session OAuth (entreprise vérifiée par
    # SUPER PDP) et entreprise ; garde l'environnement et l'entreprise.
    def check : Nil
      probe = self.probe
      probe.save(auth_mode)
      raise NotVerified.new(probe.verification) unless probe.verified?
    end

    # Ce que la plateforme dit des identifiants : état de la vérification
    # de l'entreprise (KYB) et entreprise, dont l'environnement. Une
    # entreprise non vérifiée ne répond pas à `/companies/me` (403) : seule
    # la session est alors connue.
    record Probe, verification : String, company : JSON::Any? do
      def verified? : Bool
        verification == "verified"
      end

      def env : String
        company.try(&.["env"]?.try(&.as_s?)) || ""
      end

      # Enregistre l'entreprise dans le compte du dossier.
      def save(auth_mode : String, by : Int64? = nil, connected : Bool = false) : Account
        account = Account.current!
        account.auth_mode = auth_mode
        account.verification_status = verification
        account.checked_at = Time.utc
        if connected
          account.connected_at = Time.utc
          account.connected_by_id = by
        end
        if company = self.company
          account.env = env
          account.company_id = company["id"]?.try(&.as_i64?)
          account.formal_name = company["formal_name"]?.try(&.as_s?) || ""
          account.number = company["number"]?.try(&.as_s?) || ""
          account.number_scheme = company["number_scheme"]?.try(&.as_s?) || ""
          account.country = (company["country"]?.try(&.as_s?) || "")[0, 2]? || ""
          account.vat_regime = company["vat_regime"]?.try(&.as_s?) || ""
          account.has_vat_on_debits = company["has_vat_on_debits"]?.try(&.as_bool?) || false
        end
        account.save!
        account
      end
    end

    def probe : Probe
      verification = session["company_verification_status"]?.try(&.as_s?) || "verified"
      company = verification == "verified" ? self.company : nil
      Probe.new(verification, company)
    end

    # `GET /oauth2_sessions/me` : client, état de la vérification (KYB).
    def session : JSON::Any
      client.get_json("/oauth2_sessions/me")
    end

    # `GET /companies/me` : entreprise des identifiants, dont `env`.
    def company : JSON::Any
      client.get_json("/companies/me")
    end

    # Lignes d'annuaire de l'entreprise (`GET /directory_entries`).
    def directory_entries : Array(JSON::Any)
      client.get_json("/directory_entries")["data"]?.try(&.as_a?) || [] of JSON::Any
    end

    # Régime de TVA de l'entreprise, dont dépend le calendrier de
    # l'e-reporting (`PATCH /companies`).
    def update_vat_regime(regime : String, on_debits : Bool) : JSON::Any
      client.patch_json("/companies", {"vat_regime" => regime, "has_vat_on_debits" => on_debits}.to_json)
    end

    # Validation d'une facture par le validateur de SUPER PDP
    # (`POST /validation_reports`, public) : rapport de la première.
    def validate(filename : String, content : Bytes, content_type : String) : JSON::Any
      body, type = Http.multipart([] of {String, String, String?}, [{"file", filename, content_type, content}])
      client.post_public("/validation_reports", body, type)["data"].as_a.first
    end

    # Révocation (RFC 7009) du jeton de rafraîchissement puis du jeton
    # d'accès ; les jetons sont oubliés même si la plateforme ne répond pas.
    def revoke : Bool
      refresh = client.store.refresh_token.to_s
      access = client.store.access_token.to_s
      done = client.revoke(refresh, "refresh_token") & client.revoke(access, "access_token")
      client.store.clear_refresh
      client.store.clear_access
      done
    end

    # --- Émission ------------------------------------------------------------------

    def submit(invoice : OutgoingInvoice) : Submission
      external_id = Mapping.external_id(invoice.tracking_id)
      ref = InvoiceRef.filter(external_id: external_id).first
      # Déjà déposée (retransmission) : l'état est celui de la plateforme.
      if ref && ref.state == "created" && (id = ref.platform_id)
        return submission(id.to_i64)
      end
      # Réponse perdue lors d'une tentative précédente : la facture a pu
      # être déposée ; on la cherche avant de la déposer de nouveau.
      if ref && (found = find_outgoing(external_id))
        return deposited(ref, found["id"].as_i64)
      end
      ref ||= InvoiceRef.create!(direction: "out", external_id: external_id, state: "pending")
      filename, content_type, content = payload(invoice)
      params = URI::Params.new
      params["external_id"] = external_id
      params["processing_rule"] = invoice.processing_rule
      begin
        json = client.post_file("/invoices", params, content, content_type)
      rescue ex : ApiError
        raise ex unless ex.status == 400
        # « Fichier déjà chargé » : dépôt précédent dont la réponse s'est
        # perdue ; sinon la facture est refusée au contrôle (Rejetée).
        if found = find_outgoing(external_id)
          return deposited(ref, found["id"].as_i64)
        end
        ref.delete
        return Submission.new(platform_ref: "superpdp:refused:#{external_id}:#{Random::Secure.hex(4)}", status: "error",
          reason_code: ex.code.try(&.to_s) || "", reason: ex.api_message.presence || filename)
      end
      deposited(ref, json["id"].as_i64, json["events"]?.try(&.as_a?))
    end

    # Fichier transmis : celui d'EINV, sauf pour un client étranger, servi
    # par Peppol en UBL PEPPOL BIS (ADR-004 D8, Belgique).
    def payload(invoice : OutgoingInvoice) : {String, String, Bytes}
      country = invoice.buyer.country_code
      if invoice.processing_rule != "B2C" && !country.empty? && country != "FR" && invoice.syntax != "UBL"
        file = Einvoicing::Api.export(Partiduo::Api::Actor.system, invoice.invoice_id, "peppol")
        return {file.filename, "application/xml", file.content}
      end
      type = invoice.content_type.presence || (invoice.syntax == "Factur-X" ? "application/pdf" : "application/xml")
      {invoice.filename, type, invoice.content}
    end

    private def deposited(ref : InvoiceRef, id : Int64, events : Array(JSON::Any)? = nil) : Submission
      # La facture a pu être notée entre-temps par la lecture des statuts.
      InvoiceRef.filter(platform_id: id).exclude(id: ref.id).delete
      ref.platform_id = id
      ref.state = "created"
      ref.save!
      submission(id, events)
    end

    # État d'un dépôt d'après les statuts de la facture chez la plateforme :
    # rejetée (`fr:213`, `api:invalid`…), déposée (`fr:200`) ou en attente.
    # Sert quand les statuts ont pu être lus avant que le dépôt soit connu
    # d'EINV (réponse perdue, retransmission).
    private def submission(id : Int64, events : Array(JSON::Any)? = nil) : Submission
      events ||= begin
        params = URI::Params.new
        params["invoice_id"] = id.to_s
        params["limit"] = "1000"
        client.get_json("/invoice_events", params)["data"]?.try(&.as_a?) || [] of JSON::Any
      end
      rejected = events.reverse.find { |event| Mapping.code(event["status_code"]?.try(&.as_s?) || "") == "213" }
      if rejected
        rejection = Mapping.lifecycle(rejected, "out")
        return Submission.new(platform_ref: id.to_s, status: "error", reason_code: rejection.try(&.reason_code) || "",
          reason: rejection.try(&.reason) || "")
      end
      deposited = events.any? { |event| event["status_code"]?.try(&.as_s?) == "fr:200" }
      Submission.new(platform_ref: id.to_s, status: deposited ? "ok" : "pending")
    end

    # Facture émise déjà déposée sous cet `external_id`, parmi les plus
    # récentes.
    private def find_outgoing(external_id : String) : JSON::Any?
      before = nil
      LOOKBACK_PAGES.times do
        params = URI::Params.new
        params["direction"] = "out"
        params["order"] = "desc"
        params["limit"] = PAGE_SIZE.to_s
        before.try { |id| params["ending_before_id"] = id.to_s }
        json = client.get_json("/invoices", params)
        data = json["data"].as_a
        found = data.find { |item| item["external_id"]?.try(&.as_s?) == external_id }
        return found if found
        return if data.empty? || !json["has_before"]?.try(&.as_bool?)
        before = data.last["id"].as_i64
      end
      nil
    end

    # --- Réception -----------------------------------------------------------------

    def fetch_incoming(after : Cursor?) : Page(IncomingInvoice)
      params = URI::Params.new
      params["direction"] = "in"
      params["limit"] = PAGE_SIZE.to_s
      after.try { |cursor| params["starting_after_id"] = cursor.value }
      json = client.get_json("/invoices", params)
      data = json["data"]?.try(&.as_a?) || [] of JSON::Any
      items = data.map do |item|
        id = item["id"].as_i64
        remember(id, "in")
        download = URI::Params.new
        download["format"] = "original"
        content, type = client.get_bytes("/invoices/#{id}", download)
        IncomingInvoice.new(platform_ref: id.to_s, filename: filename(id, content, type), content: content,
          received_at: Mapping.time(item["created_at"]?) || Time.utc)
      end
      cursor = data.last?.try { |item| Cursor.new(item["id"].as_i64.to_s) } || after
      Page(IncomingInvoice).new(items, cursor, json["has_after"]?.try(&.as_bool?) || false)
    end

    private def filename(id : Int64, content : Bytes, type : String) : String
      pdf = type.includes?("pdf") || (content.size > 4 && String.new(content[0, 5]) == "%PDF-")
      "superpdp-#{id}.#{pdf ? "pdf" : "xml"}"
    end

    # --- Statuts ---------------------------------------------------------------------

    def fetch_statuses(after : Cursor?) : Page(LifecycleEvent)
      params = URI::Params.new
      params["limit"] = PAGE_SIZE.to_s
      after.try { |cursor| params["starting_after_id"] = cursor.value }
      json = client.get_json("/invoice_events", params)
      data = json["data"]?.try(&.as_a?) || [] of JSON::Any
      own = SentMessage.filter(kind: "event", platform_id__in: data.map(&.["id"].as_i64)).to_a.compact_map(&.platform_id.try(&.to_i64)).to_set
      events = data.compact_map do |event|
        next if own.includes?(event["id"].as_i64)
        next unless Mapping.code(event["status_code"]?.try(&.as_s?) || "")
        direction = direction_of(event["invoice_id"].as_i64) || next
        Mapping.lifecycle(event, direction)
      end
      cursor = data.last?.try { |event| Cursor.new(event["id"].as_i64.to_s) } || after
      Page(LifecycleEvent).new(events, cursor, json["has_after"]?.try(&.as_bool?) || false)
    end

    def send_status(event : LifecycleEvent) : Nil
      invoice_id = event.invoice_ref.to_i64? || raise Einvoicing::Unsupported.new("facture inconnue de SUPER PDP", nil, "superpdp.errors.transport.unknown_invoice", {} of String => String)
      key = Mapping.event_key(event)
      message = SentMessage.filter(key: key).first
      return if message && message.state == "sent"
      status_code = "fr:#{event.code}"
      if message && (found = find_event(invoice_id, status_code, event.amount))
        return sent(message, found["id"].as_i64)
      end
      message ||= SentMessage.create!(key: key, kind: "event", state: "pending")
      payment = event.code == "212" ? payment_data(invoice_id, event) : nil
      body = {"invoice_id" => JSON::Any.new(invoice_id), "status_code" => JSON::Any.new(status_code)}
      details = Mapping.event_details(event, payment)
      body["details"] = JSON.parse(details.to_json) unless details.empty?
      begin
        json = client.post_json("/invoice_events", body.to_json)
      rescue ex : ApiError
        message.delete unless ex.server?
        raise ex
      end
      sent(message, json["id"].as_i64)
    end

    private def payment_data(invoice_id : Int64, event : LifecycleEvent) : Array(Hash(String, String))
      invoice = client.get_json("/invoices/#{invoice_id}")
      breakdown = invoice["en_invoice"]?.try(&.["vat_break_down"]?.try(&.as_a?)) || [] of JSON::Any
      currency = invoice["en_invoice"]?.try(&.["currency_code"]?.try(&.as_s?)).presence || event.currency_code
      Mapping.payment_data(breakdown, event.amount, currency, event.occurred_at)
    end

    private def find_event(invoice_id : Int64, status_code : String, amount : BigDecimal?) : JSON::Any?
      params = URI::Params.new
      params["invoice_id"] = invoice_id.to_s
      params["limit"] = "1000"
      events = client.get_json("/invoice_events", params)["data"]?.try(&.as_a?) || [] of JSON::Any
      known = SentMessage.filter(kind: "event", platform_id__in: events.map(&.["id"].as_i64)).to_a.compact_map(&.platform_id.try(&.to_i64)).to_set
      events.reverse.find do |item|
        next false if known.includes?(item["id"].as_i64) || item["status_code"]?.try(&.as_s?) != status_code
        amount.nil? || Mapping.paid_amount(item["details"]?.try(&.as_a?) || [] of JSON::Any) == amount
      end
    end

    private def sent(message : SentMessage, platform_id : Int64) : Nil
      message.platform_id = platform_id
      message.state = "sent"
      message.save!
      nil
    end

    # Sens d'une facture de la plateforme : noté au dépôt et à la réception,
    # sinon demandé à l'API (facture déposée hors de Partiduo).
    private def direction_of(invoice_id : Int64) : String?
      if ref = InvoiceRef.filter(platform_id: invoice_id).first
        return ref.direction
      end
      direction = client.get_json("/invoices/#{invoice_id}")["direction"]?.try(&.as_s?)
      remember(invoice_id, direction) if direction
      direction
    rescue ex : ApiError
      raise ex unless ex.status == 404
      nil
    end

    private def remember(invoice_id : Int64, direction : String) : Nil
      return if InvoiceRef.filter(platform_id: invoice_id).exists?
      InvoiceRef.create!(platform_id: invoice_id, direction: direction, state: "created")
      nil
    end

    # --- E-reporting ---------------------------------------------------------------

    REPORTS = {
      "international_sales"     => {"/b2bint_invoices", "b2bint_invoice"},
      "international_purchases" => {"/b2bint_invoices", "b2bint_invoice"},
      "b2c_transactions"        => {"/b2c_transactions", "b2c_transaction"},
      "b2c_payments"            => {"/b2c_payments", "b2c_payment"},
    }

    def send_ereporting(batch : EReportingBatch) : Nil
      path, kind = REPORTS[batch.kind]? || raise Einvoicing::Unsupported.new("e-reporting #{batch.kind} non proposé par SUPER PDP", nil, "superpdp.errors.transport.no_ereporting", {"kind" => batch.kind})
      pending = [] of {Hash(String, JSON::Any), SentMessage}
      remote = nil
      batch.entries.each do |entry|
        key = Mapping.report_key(batch.kind, entry)
        message = SentMessage.filter(key: key).first
        next if message && message.state == "sent"
        item = report_item(batch, entry)
        if message
          remote ||= client.get_json(path, URI::Params{"order" => "desc", "limit" => "1000"})["data"]?.try(&.as_a?) || [] of JSON::Any
          if found = remote.find { |candidate| same_report?(kind, candidate, item) }
            sent(message, found["id"].as_i64)
            next
          end
        end
        pending << {item, message || SentMessage.create!(key: key, kind: kind, state: "pending")}
      end
      return if pending.empty?
      begin
        json = client.post_json(path, {"data" => pending.map(&.[0])}.to_json)
      rescue ex : ApiError
        pending.each(&.[1].delete) unless ex.server?
        raise ex
      end
      created = json["data"]?.try(&.as_a?) || [] of JSON::Any
      pending.each_with_index do |(_, message), index|
        created[index]?.try { |item| sent(message, item["id"].as_i64) }
      end
    end

    private def report_item(batch : EReportingBatch, entry : EReportingEntry) : Hash(String, JSON::Any)
      case batch.kind
      when "international_sales"     then Mapping.b2bint_invoice(entry, batch.declarant, "out")
      when "international_purchases" then Mapping.b2bint_invoice(entry, batch.declarant, "in")
      when "b2c_transactions"        then Mapping.b2c_transaction(entry)
      else                                Mapping.b2c_payment(entry)
      end
    end

    # Ligne d'e-reporting déjà enregistrée chez la plateforme : même
    # numéro, date et montants (facture internationale), même date et
    # montants (B2C).
    private def same_report?(kind : String, candidate : JSON::Any, item : Hash(String, JSON::Any)) : Bool
      case kind
      when "b2bint_invoice"
        candidate["number"]?.try(&.as_s?) == item["number"].as_s &&
          candidate["issue_date"]?.try(&.as_s?) == item["issue_date"].as_s &&
          candidate["direction"]?.try(&.as_s?) == item["direction"].as_s
      when "b2c_transaction"
        candidate["date"]?.try(&.as_s?) == item["date"].as_s &&
          Mapping::Formats.decimal(candidate["tax_exclusive_amount"]?.try(&.as_s?)) ==
            Mapping::Formats.decimal(item["tax_exclusive_amount"].as_s)
      else
        candidate["date"]?.try(&.as_s?) == item["date"].as_s &&
          candidate["subtotals"]?.try(&.as_a?).try(&.first?).try(&.["amount"]?).try(&.as_s?).try { |text| Mapping::Formats.decimal(text) } ==
            Mapping::Formats.decimal(item["subtotals"][0]["amount"].as_s)
      end
    end

    # --- Annuaire --------------------------------------------------------------------

    def lookup(query : String) : Array(DirectoryEntry)
      value = query.gsub(/\s/, "")
      if value.matches?(/\A(?:0208:|BE)?[01]\d{9}\z/i)
        number = value.sub(/\A(?:0208:|BE)/i, "")
        return [Mapping.directory_entry("0208:#{number}", "", nil, "peppol")]
      end
      address = value.lchop("0225:")
      if address.matches?(/\A\d{9}(?:_[A-Za-z0-9_\-.]+)?\z/)
        siren = address[0, 9]
        entries = french_entries(siren)
        entries = entries.select { |entry| entry.address.downcase == address.downcase } unless address == siren
        return entries
      end
      if value.matches?(/\A\d{14}\z/)
        return french_entries(value[0, 9]).select { |entry| entry.siret == value }
      end
      params = URI::Params.new
      params["formal_name_starts_with"] = query.strip
      params["limit"] = "50"
      companies = client.get_json("/french_directory/companies", params)["data"]?.try(&.as_a?) || [] of JSON::Any
      companies.map do |company|
        number = company["number"]?.try(&.as_s?) || ""
        Mapping.directory_entry("0225:#{number}", company["formal_name"]?.try(&.as_s?) || "", nil)
      end
    end

    private def french_entries(siren : String) : Array(DirectoryEntry)
      params = URI::Params.new
      params["number"] = siren
      data = client.get_json("/french_directory/entries", params)["data"]?.try(&.as_a?) || [] of JSON::Any
      data.map do |item|
        name = item["company"]?.try(&.["formal_name"]?.try(&.as_s?)) || ""
        Mapping.directory_entry(item["identifier"].as_s, name, item["is_active"]?.try(&.as_bool?))
      end
    end
  end
end
