# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/formdata"
require "mime/multipart"
require "digest/sha256"
require "base64"
require "openssl"

module Superpdp
  module SpecSupport
    # SUPER PDP simulée (ADR-004 D6, D8) : double du transport HTTP d'EINV
    # qui reproduit les réponses documentées de l'API JSON
    # (`https://api.superpdp.tech/openapi/superpdp.json`, version
    # 1.35.0.beta, et pages Authentification, Erreurs, Annuaire,
    # Synchronisation, E-reporting), vérifiées contre le bac à sable le
    # 27/09/2026 :
    #
    # * OAuth 2.1 : `client_credentials`, `authorization_code` avec PKCE
    #   `S256`, `refresh_token` à usage unique (rotation), révocation
    #   RFC 7009, jetons d'accès expirables ;
    # * identifiants d'objets strictement croissants, pagination
    #   `starting_after_id` / `ending_before_id` / `has_after` ;
    # * factures acheminées d'une entreprise à l'autre par l'adresse
    #   électronique de l'acheteur (`0225:…`, `0208:…`), statuts
    #   `api:uploaded`, `fr:200`, `fr:201`, `fr:202` ; « Fichier déjà
    #   chargé » pour un contenu identique ;
    # * statuts émis recopiés sur la facture de l'autre partie ; règle
    #   BR-FR-CDV-14 (« Encaissée » : montant et taux par bloc `MEN`) ;
    # * erreurs `http_ko` (`http_status_code`, `message`).
    #
    # Les specs y créent des entreprises, y déposent des factures et lisent
    # ce que l'extension y a envoyé ; elles y injectent des pannes (429,
    # 503, réponse perdue).
    class SimulatedSuperpdp < Einvoicing::Http::Transport
      alias Request = Einvoicing::Http::Request
      alias Response = Einvoicing::Http::Response

      HOST = "api.superpdp.tech"

      OPERATOR_CLIENT_ID     = "operator-app"
      OPERATOR_CLIENT_SECRET = "operator-s3cret"
      REDIRECT_URI           = "https://demo.partiduo.test/ext/SUPERPDP/oauth/callback"

      class Company
        property id : Int64
        property env : String
        property number : String
        property number_scheme : String
        property formal_name : String
        property country : String
        property vat_regime : String = ""
        property? has_vat_on_debits : Bool = false
        property verification : String = "verified"
        property identifiers : Array(String)
        property client_id : String
        property client_secret : String
        property email : String

        def initialize(@id, @env, @number, @number_scheme, @formal_name, @country, @identifiers, @client_id,
                       @client_secret, @email)
        end

        def to_json_any : Hash(String, JSON::Any)
          JSON.parse({
            "id" => id, "created_at" => "2026-09-01T08:00:00Z", "env" => env, "number_scheme" => number_scheme,
            "number" => number, "formal_name" => formal_name, "trade_name" => "", "address" => "1 rue du Port",
            "postcode" => "75001", "city" => "Paris", "country" => country, "vat_regime" => vat_regime,
            "has_vat_on_debits" => has_vat_on_debits?,
          }.to_json).as_h
        end
      end

      class Invoice
        property id : Int64
        property company_id : Int64
        property direction : String
        property external_id : String?
        property content : Bytes
        property content_type : String
        property created_at : Time
        property processing_rule : String
        property twin_id : Int64? = nil

        def initialize(@id, @company_id, @direction, @external_id, @content, @content_type, @created_at, @processing_rule)
        end
      end

      class Event
        property id : Int64
        property invoice_id : Int64
        property company_id : Int64
        property status_code : String
        property status_text : String
        property created_at : Time
        property details : JSON::Any?

        def initialize(@id, @invoice_id, @company_id, @status_code, @status_text, @created_at, @details = nil)
        end

        def to_json_any : Hash(String, JSON::Any)
          hash = {"id" => JSON::Any.new(id), "created_at" => JSON::Any.new(created_at.to_rfc3339(fraction_digits: 6)),
                  "invoice_id" => JSON::Any.new(invoice_id), "status_code" => JSON::Any.new(status_code),
                  "status_text" => JSON::Any.new(status_text)}
          details.try { |value| hash["details"] = value }
          hash
        end
      end

      STATUS_TEXTS = {
        "api:uploaded" => "Téléversée", "api:invalid" => "Invalide", "fr:200" => "Déposée (validée)",
        "fr:201" => "Émise par la plateforme", "fr:202" => "Reçue par la plateforme", "fr:204" => "Prise en charge",
        "fr:205" => "Approuvée", "fr:206" => "Approuvée partiellement", "fr:207" => "En litige", "fr:208" => "Suspendue",
        "fr:209" => "Complétée", "fr:210" => "Refusée (par l’acheteur)", "fr:211" => "Paiement transmis",
        "fr:212" => "Encaissée", "fr:213" => "Rejetée (par la plateforme)", "fr:220" => "Annulée",
      }

      getter companies = [] of Company
      getter invoices = [] of Invoice
      getter events = [] of Event
      getter requests = [] of Request
      getter revoked = [] of String
      getter b2bint = [] of Hash(String, JSON::Any)
      getter b2c_transactions = [] of Hash(String, JSON::Any)
      getter b2c_payments = [] of Hash(String, JSON::Any)
      # Réponses d'erreur forcées pour les prochaines requêtes d'API.
      getter failures = [] of Int32
      # La prochaine requête d'API de cette forme (`"POST /invoices"`) est
      # traitée mais sa réponse se perd (coupure réseau).
      property lose_next : String? = nil
      # Taille maximale d'une page (petite, pour tester la pagination).
      property max_page : Int32 = 1000
      # Motif de rejet (fr:213) du prochain dépôt.
      property reject_next : String? = nil

      @access = {} of String => {Int64, Time}
      @refresh = {} of String => Int64
      @codes = {} of String => {Int64, String, String}
      @sequence = 1000_i64
      @clock = Time.utc(2026, 9, 27, 8, 0, 0)

      def tick : Time
        @clock += 1.second
      end

      # --- Côté plateforme : ce que les specs préparent -----------------------------

      def add_company(formal_name : String, number : String, identifiers : Array(String), env : String = "sandbox",
                      scheme : String = "fr_siren", country : String = "FR", email : String = "compta@example.test") : Company
        id = next_id
        company = Company.new(id, env, number, scheme, formal_name, country, identifiers, "client-#{id}",
          "secret-#{id}-#{Random::Secure.hex(4)}", email)
        companies << company
        company
      end

      def company(client_id : String) : Company
        companies.find { |item| item.client_id == client_id } || raise "entreprise #{client_id} inconnue"
      end

      # Consentement de l'utilisateur au bout du parcours d'inscription :
      # contrôle l'adresse d'autorisation et rend le code et le `state` que
      # SUPER PDP renverrait à la route de rappel.
      def consent(authorize_url : String, company : Company) : {String, String}
        uri = URI.parse(authorize_url)
        raise "autorisation hors SUPER PDP : #{authorize_url}" unless uri.host == HOST && uri.path == "/oauth2/authorize"
        params = uri.query_params
        raise "response_type" unless params["response_type"]? == "code"
        raise "client_id" unless params["client_id"]? == OPERATOR_CLIENT_ID
        raise "PKCE S256 attendu" unless params["code_challenge_method"]? == "S256" && params["code_challenge"]?
        code = "code-#{Random::Secure.hex(8)}"
        @codes[code] = {company.id, params["redirect_uri"], params["code_challenge"]}
        {code, params["state"]}
      end

      # Facture déposée par une autre entreprise (`sender`) à destination
      # de `recipient`.
      def deliver(sender : Company, recipient : Company, content : Bytes, content_type : String = "application/xml") : Invoice
        upload(sender, content, content_type, nil, "B2B", recipient)
      end

      # Statut émis par une entreprise sur une de ses factures.
      def emit(company : Company, invoice : Invoice, status_code : String, details = nil) : Event
        event = add_event(invoice, status_code, details.try { |value| JSON.parse(value.to_json) })
        mirror(invoice, status_code, event.details)
        event
      end

      def invoices_of(company : Company, direction : String? = nil) : Array(Invoice)
        invoices.select { |item| item.company_id == company.id && (direction.nil? || item.direction == direction) }
      end

      def events_of(invoice : Invoice) : Array(Event)
        events.select { |item| item.invoice_id == invoice.id }
      end

      def expire_access_tokens! : Nil
        @access.transform_values! { |(company, _)| {company, Time.utc - 1.minute} }
      end

      def refresh_tokens : Array(String)
        @refresh.keys
      end

      # Jetons de rafraîchissement révoqués par ailleurs (compte abandonné,
      # autorisation retirée dans SUPER PDP).
      def forget_refresh_tokens! : Nil
        @refresh.clear
      end

      def fail_next(*statuses : Int32) : Nil
        failures.concat(statuses.to_a)
      end

      def api_requests(path : String, method : String? = nil) : Array(Request)
        requests.select { |request| URI.parse(request.url).path == "/v1.beta#{path}" && (method.nil? || request.method == method) }
      end

      # --- Transport -------------------------------------------------------------------

      def exec(request : Request) : Response
        @requests << request
        uri = URI.parse(request.url)
        raise "hôte inattendu #{uri.host}" unless uri.host == HOST
        raise "HTTPS exigé" unless uri.scheme == "https"
        case uri.path
        when "/oauth2/token"  then return token(form(request))
        when "/oauth2/revoke" then return revoke(form(request))
        end
        path = uri.path.lchop?("/v1.beta") || return ko(404)
        return validation(request) if path == "/validation_reports" && request.method == "POST"
        company = authenticate(request) || return ko(401)
        if company.verification != "verified" && path != "/oauth2_sessions/me"
          return ko(403, "company not verified")
        end
        if status = failures.shift?
          return ko(status, status == 429 ? "too many requests" : "service unavailable")
        end
        response = route(request, uri, path, company)
        if lose_next == "#{request.method} #{path}"
          @lose_next = nil
          raise Einvoicing::ConnectorError.new("#{HOST} injoignable : connexion interrompue")
        end
        response
      end

      private def route(request : Request, uri : URI, path : String, company : Company) : Response
        params = uri.query_params
        case {request.method, path}
        when {"GET", "/oauth2_sessions/me"}
          json(200, {"client_id" => company.client_id, "created_at" => "2026-09-27T08:00:00Z",
                     "company_verification_status" => company.verification})
        when {"GET", "/companies/me"} then json(200, company.to_json_any)
        when {"PATCH", "/companies"}  then patch_company(request, company)
        when {"GET", "/invoices"}     then list_invoices(params, company)
        when {"POST", "/invoices"}    then create_invoice(request, params, company)
        when {"GET", "/invoice_events"}
          list_events(params, company)
        when {"POST", "/invoice_events"}
          create_event(request, company)
        when {"GET", "/directory_entries"}
          entries = company.identifiers.map_with_index do |identifier, index|
            {"id" => company.id * 10 + index, "company" => company.to_json_any, "directory" => "peppol",
             "identifier" => identifier, "created_at" => "2026-09-01T08:00:00Z", "status" => "created",
             "is_replyto" => identifier.ends_with?("_replyto")}
          end
          json(200, {"data" => entries})
        when {"GET", "/french_directory/entries"}, {"GET", "/french_directory/companies"}
          french_directory(path, params)
        when {"POST", "/b2bint_invoices"}  then ereporting(request, company, b2bint, true)
        when {"GET", "/b2bint_invoices"}   then json(200, {"data" => b2bint, "has_more" => false})
        when {"POST", "/b2c_transactions"} then ereporting(request, company, b2c_transactions, true)
        when {"GET", "/b2c_transactions"}  then json(200, {"data" => b2c_transactions, "has_more" => false})
        when {"POST", "/b2c_payments"}     then ereporting(request, company, b2c_payments, false)
        when {"GET", "/b2c_payments"}      then json(200, {"data" => b2c_payments, "has_more" => false})
        else
          if request.method == "GET" && (id = path.lchop?("/invoices/").try(&.to_i64?))
            show_invoice(id, params, company)
          else
            ko(404)
          end
        end
      end

      private def french_directory(path : String, params : URI::Params) : Response
        if path.ends_with?("/entries")
          number = params["number"]? || return ko(400, "number is required")
          data = companies.select { |item| item.number == number && item.number_scheme == "fr_siren" }.flat_map do |item|
            item.identifiers.reject(&.ends_with?("_replyto")).map do |identifier|
              {"company" => french_company(item), "identifier" => identifier, "is_active" => true}
            end
          end
          json(200, {"data" => data})
        else
          prefix = params["formal_name_starts_with"]?.to_s.downcase
          data = companies.select { |item| item.number_scheme == "fr_siren" && item.formal_name.downcase.starts_with?(prefix) }
          json(200, {"data" => data.map { |item| french_company(item) }, "has_more" => false})
        end
      end

      # --- OAuth 2.1 -------------------------------------------------------------------

      private def token(form : URI::Params) : Response
        client_id = form["client_id"]?.to_s
        secret = form["client_secret"]?.to_s
        operator = client_id == OPERATOR_CLIENT_ID && secret == OPERATOR_CLIENT_SECRET
        company = companies.find { |item| item.client_id == client_id && item.client_secret == secret }
        return oauth_error(401, "invalid_client") unless operator || company
        case form["grant_type"]?
        when "client_credentials"
          return oauth_error(400, "unauthorized_client") if company.nil?
          issue(company.id, refresh: false)
        when "authorization_code"
          return oauth_error(400, "unauthorized_client") unless operator
          grant = @codes.delete(form["code"]?.to_s) || return oauth_error(400, "invalid_grant")
          company_id, redirect, challenge = grant
          return oauth_error(400, "invalid_grant") unless form["redirect_uri"]? == redirect
          verifier = form["code_verifier"]?.to_s
          expected = Base64.urlsafe_encode(OpenSSL::Digest.new("SHA256").update(verifier).final, padding: false)
          return oauth_error(400, "invalid_grant") unless expected == challenge
          issue(company_id, refresh: true)
        when "refresh_token"
          return oauth_error(400, "unauthorized_client") unless operator
          company_id = @refresh.delete(form["refresh_token"]?.to_s) || return oauth_error(400, "invalid_grant")
          issue(company_id, refresh: true)
        else
          oauth_error(400, "unsupported_grant_type")
        end
      end

      private def issue(company_id : Int64, refresh : Bool) : Response
        access = "at-#{Random::Secure.hex(12)}"
        @access[access] = {company_id, Time.utc + 30.minutes}
        body = {"access_token" => access, "expires_in" => 1799, "scope" => "", "token_type" => "bearer"} of String => String | Int32
        if refresh
          value = "rt-#{Random::Secure.hex(12)}"
          @refresh[value] = company_id
          body["refresh_token"] = value
        end
        json(200, body)
      end

      private def revoke(form : URI::Params) : Response
        client_id = form["client_id"]?.to_s
        known = (client_id == OPERATOR_CLIENT_ID && form["client_secret"]? == OPERATOR_CLIENT_SECRET) ||
                companies.any? { |item| item.client_id == client_id && item.client_secret == form["client_secret"]? }
        return oauth_error(401, "invalid_client") unless known
        token = form["token"]?.to_s
        @revoked << token
        if company_id = @refresh.delete(token)
          @access.reject! { |_, (owner, _)| owner == company_id }
        end
        @access.delete(token)
        Response.new(200, {} of String => String, Bytes.empty)
      end

      private def authenticate(request : Request) : Company?
        bearer = request.headers["Authorization"]?.to_s.lchop?("Bearer ") || return
        company_id, expires = @access[bearer]? || return
        return if expires < Time.utc
        companies.find { |item| item.id == company_id }
      end

      # --- Factures ---------------------------------------------------------------------

      private def list_invoices(params : URI::Params, company : Company) : Response
        rows = invoices_of(company, params["direction"]?)
        page(rows, params) { |item| overview(item) }.try { |body| json(200, body) } || ko(400, "invalid pagination")
      end

      private def page(rows : Array(T), params : URI::Params, &block : T -> Hash(String, JSON::Any)) forall T
        after = params["starting_after_id"]?
        before = params["ending_before_id"]?
        return if (after && after.to_i64?.nil?) || (before && before.to_i64?.nil?)
        limit = Math.min(params["limit"]?.try(&.to_i?) || 100, max_page)
        desc = params["order"]? == "desc"
        sorted = rows.sort_by(&.id)
        sorted.reverse! if desc
        window = sorted.select do |item|
          (after.nil? || item.id > after.to_i64) && (before.nil? || item.id < before.to_i64)
        end
        chunk = window.first(limit)
        ids = chunk.map(&.id)
        body = {} of String => JSON::Any
        body["data"] = JSON::Any.new(chunk.map { |item| JSON::Any.new(block.call(item)) })
        body["count"] = JSON::Any.new(rows.size.to_i64)
        lowest = ids.min?
        highest = ids.max?
        body["has_after"] = JSON::Any.new(highest ? rows.any? { |item| item.id > highest } : false)
        body["has_before"] = JSON::Any.new(lowest ? rows.any? { |item| item.id < lowest } : false)
        body
      end

      private def overview(invoice : Invoice) : Hash(String, JSON::Any)
        hash = {"id" => JSON::Any.new(invoice.id), "company_id" => JSON::Any.new(invoice.company_id),
                "created_at" => JSON::Any.new(invoice.created_at.to_rfc3339(fraction_digits: 6)),
                "direction" => JSON::Any.new(invoice.direction), "processing_rule" => JSON::Any.new(invoice.processing_rule)}
        invoice.external_id.try { |value| hash["external_id"] = JSON::Any.new(value) }
        hash
      end

      private def create_invoice(request : Request, params : URI::Params, company : Company) : Response
        content = request.body || Bytes.empty
        type = request.headers["Content-Type"]?.to_s
        return ko(400, "unsupported content type") unless type.in?("application/pdf", "application/xml")
        return ko(400, "Fichier déjà chargé") if invoices.any? { |item| item.company_id == company.id && item.content == content }
        external_id = params["external_id"]?
        return ko(400, "external_id too long") if external_id && external_id.size > 36
        parsed = begin
          Einvoicing::Formats::Reader.parse(content)
        rescue Einvoicing::Formats::ReadError
          return ko(400, "invalid XML structure")
        end
        rule = params["processing_rule"]? || "B2B"
        b2c = parsed.notes.any?(&.includes?("B2C")) || String.new(parsed.xml).includes?("<ram:SubjectCode>BAR</ram:SubjectCode>")
        computed = b2c ? "B2C" : "B2B"
        if rule != computed && rule.in?("B2B", "B2C")
          return ko(400, "processing rule mismatch: computed #{computed}, given #{rule}")
        end
        invoice = upload(company, content, type, external_id, computed)
        # Comme SUPER PDP : la réponse ne porte que « Téléversée », la suite
        # du traitement est asynchrone.
        uploaded = events_of(invoice).first(1).map { |item| JSON::Any.new(item.to_json_any) }
        json(200, overview(invoice).merge({"events" => JSON::Any.new(uploaded)}))
      end

      private def upload(company : Company, content : Bytes, type : String, external_id : String?, rule : String,
                         recipient : Company? = nil) : Invoice
        invoice = Invoice.new(next_id, company.id, "out", external_id, content, type, tick, rule)
        invoices << invoice
        add_event(invoice, "api:uploaded")
        if reason = reject_next
          @reject_next = nil
          add_event(invoice, "fr:213", JSON.parse([{"reason" => "REJ_SEMAN", "notes" => [{"contents" => [{"content" => reason}]}]}].to_json))
          return invoice
        end
        parsed = Einvoicing::Formats::Reader.parse(content)
        if rule == "B2C"
          add_event(invoice, "fr:200", JSON.parse("[{}]"))
          return invoice
        end
        address = "#{parsed.buyer.scheme}:#{parsed.buyer.electronic_address}"
        recipient ||= companies.find { |item| item.id != company.id && item.identifiers.any? { |id| id.downcase == address.downcase } }
        if recipient.nil?
          add_event(invoice, "api:invalid", JSON.parse([{"reason" => "DEST_INC", "notes" => [{"contents" => [{"content" => "destinataire #{address} introuvable"}]}]}].to_json))
          return invoice
        end
        add_event(invoice, "fr:200", JSON.parse("[{}]"))
        add_event(invoice, "fr:201")
        received = Invoice.new(next_id, recipient.id, "in", nil, content, type, tick, rule)
        received.twin_id = invoice.id
        invoice.twin_id = received.id
        invoices << received
        add_event(received, "fr:202", JSON.parse("[{}]"))
        add_event(invoice, "fr:202", JSON.parse("[{}]"))
        invoice
      end

      private def show_invoice(id : Int64, params : URI::Params, company : Company) : Response
        invoice = invoices.find { |item| item.id == id && item.company_id == company.id } || return ko(404)
        if params["format"]? == "original"
          return Response.new(200, {"content-type" => invoice.content_type}, invoice.content)
        end
        parsed = Einvoicing::Formats::Reader.parse(invoice.content)
        breakdown = parsed.vat_lines.map do |line|
          {"vat_category_taxable_amount" => Einvoicing::Formats.amount(line.base),
           "vat_category_tax_amount" => Einvoicing::Formats.amount(line.amount), "vat_category_code" => line.category,
           "vat_identifier" => "VAT", "vat_category_rate" => Einvoicing::Formats.amount(line.percent)}
        end
        en_invoice = {"number" => parsed.number, "currency_code" => parsed.currency_code, "vat_break_down" => breakdown}
        json(200, overview(invoice).merge({"en_invoice" => JSON.parse(en_invoice.to_json),
                                           "events"     => JSON::Any.new(events_of(invoice).map { |item| JSON::Any.new(item.to_json_any) })}))
      end

      # --- Statuts ------------------------------------------------------------------------

      private def list_events(params : URI::Params, company : Company) : Response
        rows = events.select { |item| item.company_id == company.id }
        if invoice_id = params["invoice_id"]?.try(&.to_i64?)
          rows = rows.select { |item| item.invoice_id == invoice_id }
        end
        body = page(rows, params, &.to_json_any) || return ko(400, "invalid pagination")
        body.delete("count")
        body.delete("has_before")
        json(200, body)
      end

      private def create_event(request : Request, company : Company) : Response
        body = JSON.parse(String.new(request.body || Bytes.empty))
        invoice_id = body["invoice_id"]?.try(&.as_i64?) || return ko(400, "invoice_id is required")
        status_code = body["status_code"]?.try(&.as_s?) || return ko(400, "status_code is required")
        invoice = invoices.find { |item| item.id == invoice_id && item.company_id == company.id } || return ko(404)
        return ko(400, "invalid status_code") unless STATUS_TEXTS.has_key?(status_code) && status_code.starts_with?("fr:")
        details = body["details"]?
        if status_code == "fr:212"
          blocks = details.try(&.as_a?).try(&.flat_map { |detail| detail["reported_data"]?.try(&.as_a?) || [] of JSON::Any }) || [] of JSON::Any
          men = blocks.select { |data| data["type_code"]?.try(&.as_s?) == "MEN" }
          if !details.nil? && (men.empty? || men.any? { |data| data["amount"]?.nil? || data["value_percent"]?.nil? })
            return ko(400, "[BR-FR-CDV-14/MDT-207] : Si le statut est \"Encaissé\" (MDT-105 = 212), ALORS il doit y avoir au moins 1 Bloc MDG-43 avec une valeur de MDT-207 = MEN et tous les blocs MDG-43 avec une valeur MDT-207 = \"MEN\" doivent contenir une valeur MDT-215 (Montant) et une valeur de MDT-224 (pourcentage de TVA).")
          end
        end
        if status_code == "fr:210" && details.try(&.as_a?.try(&.any? { |detail| detail["reason"]? })) != true
          return ko(400, "a reason is required to refuse an invoice")
        end
        event = add_event(invoice, status_code, details)
        mirror(invoice, status_code, details)
        json(200, event.to_json_any)
      end

      # Statut recopié sur la facture de l'autre partie.
      private def mirror(invoice : Invoice, status_code : String, details : JSON::Any?) : Nil
        twin = invoice.twin_id.try { |id| invoices.find { |item| item.id == id } }
        add_event(twin, status_code, details) if twin
      end

      private def add_event(invoice : Invoice, status_code : String, details : JSON::Any? = nil) : Event
        event = Event.new(next_id, invoice.id, invoice.company_id, status_code, STATUS_TEXTS[status_code]? || status_code, tick, details)
        events << event
        event
      end

      # --- Entreprise, e-reporting, validation ------------------------------------------------

      private def patch_company(request : Request, company : Company) : Response
        body = JSON.parse(String.new(request.body || Bytes.empty))
        regime = body["vat_regime"]?.try(&.as_s?) || return ko(400, "vat_regime is required")
        return ko(400, "invalid vat_regime") unless regime.in?("monthly", "quarterly", "simplified", "vat_exemption")
        company.vat_regime = regime
        company.has_vat_on_debits = body["has_vat_on_debits"]?.try(&.as_bool?) || false
        json(200, {"vat_regime" => regime, "has_vat_on_debits" => company.has_vat_on_debits?})
      end

      private def ereporting(request : Request, company : Company, store : Array(Hash(String, JSON::Any)), regime : Bool) : Response
        return ko(400, "The VAT regime needs to be setup at the company level.") if regime && company.vat_regime.empty?
        body = JSON.parse(String.new(request.body || Bytes.empty))
        data = body["data"]?.try(&.as_a?) || return ko(400, "data is required")
        created = data.map do |item|
          record = item.as_h.dup
          record["id"] = JSON::Any.new(next_id)
          store << record
          JSON::Any.new(record)
        end
        json(200, {"data" => created, "has_more" => false})
      end

      private def validation(request : Request) : Response
        boundary = MIME::Multipart.parse_boundary(request.headers["Content-Type"]? || "") || return ko(400, "multipart expected")
        name = ""
        size = 0
        valid = false
        HTTP::FormData.parse(IO::Memory.new(request.body || Bytes.empty), boundary) do |part|
          name = part.filename || "file"
          content = part.body.getb_to_end
          size = content.size
          valid = !Einvoicing::Formats::Reader.detect(content).nil?
        end
        json(200, {"data" => [{"file_name" => name, "file_size" => size, "is_valid" => valid, "duration" => 12,
                               "subreports" => [] of String}]})
      end

      private def french_company(company : Company) : Hash(String, String)
        {"address" => "1 rue du Port", "city" => "Paris", "country" => company.country, "formal_name" => company.formal_name,
         "number" => company.number, "postcode" => "75001"}
      end

      # --- Outils -------------------------------------------------------------------------------

      private def form(request : Request) : URI::Params
        URI::Params.parse(String.new(request.body || Bytes.empty))
      end

      private def next_id : Int64
        @sequence += 1
      end

      private def ko(status : Int32, message : String? = nil) : Response
        body = {"http_status_code" => JSON::Any.new(status.to_i64)}
        message.try { |text| body["message"] = JSON::Any.new(text) }
        json(status, body)
      end

      private def oauth_error(status : Int32, error : String) : Response
        json(status, {"error" => error, "error_description" => "#{error} (simulated)"})
      end

      private def json(status : Int32, body) : Response
        Response.new(status, {"content-type" => "application/json"}, body.to_json.to_slice)
      end
    end
  end
end
