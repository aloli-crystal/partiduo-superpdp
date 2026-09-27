# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"
require "json"

module Superpdp
  # Correspondances entre l'API JSON SUPER PDP et les types de
  # `Einvoicing::Connector` : statuts, montants encaissés par taux,
  # annuaire, e-reporting. Fonctions pures, sans réseau ni base. Interne.
  module Mapping
    alias Connector = Einvoicing::Connector
    alias Formats = Einvoicing::Formats

    # Statuts `api:*` (propres à SUPER PDP, factures Peppol) repris dans le
    # cycle de vie : erreur avant l'envoi ou refus du point d'accès distant
    # → Rejetée (213). Les autres (`api:uploaded`, `api:validated`,
    # `api:sent`…) et les statuts `ppf:*` ne sont que des étapes techniques.
    API_STATUSES = {"api:invalid" => "213", "api:rejected" => "213"}

    # Statuts émis par l'acheteur (XP Z12-012) : sur une facture émise, ils
    # viennent du client ; les autres codes `fr:*` de la plateforme, sauf
    # « Encaissée » (212), émis par le vendeur.
    BUYER_CODES = %w[204 205 206 207 208 209 210 211]

    # Statuts qui portent un motif (bloc MDG-39 et code MDT-113).
    REASON_CODES = %w[206 207 208 210]

    # Pays de l'Union européenne (catégorie de TVA `K` d'une livraison
    # intracommunautaire, sinon `G` export).
    EU = %w[AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK]

    # Identifiant de dépôt (`external_id`, 36 caractères au plus) tiré du
    # `tracking_id` d'EINV (`PDUO-<uuid>`).
    def self.external_id(tracking_id : String) : String
      value = tracking_id.lchop("PDUO-")
      value.size <= 36 ? value : Digest::SHA256.hexdigest(tracking_id)[0, 36]
    end

    # Code AFNOR d'un statut SUPER PDP, `nil` s'il n'entre pas dans le cycle
    # de vie. `fr:501` (Irrecevable, PPF) est rendu comme un rejet.
    def self.code(status_code : String) : String?
      if code = status_code.lchop?("fr:")
        return "213" if code == "501"
        code.matches?(/\A\d{3}\z/) ? code : nil
      else
        API_STATUSES[status_code]?
      end
    end

    def self.issuer(code : String) : String
      return "buyer" if BUYER_CODES.includes?(code)
      code == "212" ? "seller" : "platform"
    end

    # Événement du cycle de vie tiré d'un `event` de `GET /invoice_events`,
    # pour une facture de sens `direction` (`in` ou `out`) ; `nil` si ce
    # n'est pas un statut du cycle de vie.
    def self.lifecycle(event : JSON::Any, direction : String) : Connector::LifecycleEvent?
      status_code = event["status_code"]?.try(&.as_s?) || return
      code = code(status_code) || return
      details = event["details"]?.try(&.as_a?) || [] of JSON::Any
      reason_code = details.compact_map(&.["reason"]?.try(&.as_s?).presence).first? || ""
      reason_code = "501" if status_code == "fr:501" && reason_code.empty?
      notes = details.flat_map do |detail|
        (detail["notes"]?.try(&.as_a?) || [] of JSON::Any).flat_map do |note|
          (note["contents"]?.try(&.as_a?) || [] of JSON::Any).compact_map { |content| content["content"]?.try(&.as_s?) }
        end
      end
      reason = notes.reject(&.empty?).join(" ").presence ||
               event["data"]?.try(&.["reason"]?.try(&.as_s?)) || ""
      reason = event["status_text"]?.try(&.as_s?) || "" if reason.empty? && code == "213"
      amount = code == "212" ? paid_amount(details) : nil
      id = event["id"].as_i64
      Connector::LifecycleEvent.new(
        code: code, occurred_at: time(event["created_at"]?) || Time.utc,
        direction: direction == "in" ? "incoming" : "outgoing",
        invoice_ref: event["invoice_id"].as_i64.to_s, issuer: issuer(code), reason_code: reason_code,
        reason: reason, amount: amount, platform_ref: "superpdp:event:#{id}")
    end

    # Montant encaissé : somme des données `MEN` (TTC par taux).
    def self.paid_amount(details : Array(JSON::Any)) : BigDecimal?
      amounts = details.flat_map do |detail|
        (detail["reported_data"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |data|
          next unless data["type_code"]?.try(&.as_s?) == "MEN"
          Formats.decimal(data["amount"]?.try(&.as_s?))
        end
      end
      amounts.empty? ? nil : amounts.sum(BigDecimal.new(0))
    end

    # Ventilation d'un encaissement par taux de TVA (bloc MDG-43 de
    # « Encaissée », règle BR-FR-CDV-14 : un montant `MEN` et un taux par
    # bloc). `breakdown` : `vat_break_down` de la facture (base et TVA par
    # taux). Un encaissement partiel est réparti au prorata du TTC de chaque
    # taux, arrondi au centime, l'écart d'arrondi sur le dernier taux ;
    # `amount` à `nil` : la facture entière.
    def self.payment_data(breakdown : Array(JSON::Any), amount : BigDecimal?, currency : String,
                          date : Time) : Array(Hash(String, String))
      rates = breakdown.compact_map do |line|
        taxable = Formats.decimal(line["vat_category_taxable_amount"]?.try(&.as_s?)) || next
        tax = Formats.decimal(line["vat_category_tax_amount"]?.try(&.as_s?)) || BigDecimal.new(0)
        rate = Formats.decimal(line["vat_category_rate"]?.try(&.as_s?)) || BigDecimal.new(0)
        {rate, taxable + tax}
      end
      raise Einvoicing::ConnectorError.new("facture SUPER PDP sans récapitulatif de TVA") if rates.empty?
      total = rates.sum(BigDecimal.new(0)) { |(_, gross)| gross }
      paid = amount || total
      shares = if total.zero? || paid == total
                 rates.map { |(_, gross)| gross }
               else
                 allocated = BigDecimal.new(0)
                 rates.map_with_index do |(_, gross), index|
                   share = index == rates.size - 1 ? paid - allocated : (paid * gross / total).round(2, mode: :ties_away)
                   allocated += share
                   share
                 end
               end
      rates.zip(shares).map do |(rate, _), share|
        {"type_code" => "MEN", "amount" => Formats.amount(share), "currency_code" => currency,
         "value_percent" => Formats.amount(rate), "date" => date.to_s("%Y-%m-%d")}
      end
    end

    # Clé stable d'un statut émis (reprise idempotente).
    def self.event_key(event : Connector::LifecycleEvent) : String
      parts = [event.invoice_ref, event.code, event.occurred_at.to_unix.to_s, event.amount.try { |value| Formats.amount(value) } || "",
               event.reason_code]
      "event:#{Digest::SHA256.hexdigest(parts.join('|'))}"
    end

    # Détails d'un statut émis : motif et note (MDG-39) pour un refus,
    # encaissement par taux (MDG-43) pour « Encaissée ».
    def self.event_details(event : Connector::LifecycleEvent, payment : Array(Hash(String, String))?) : Array(Hash(String, JSON::Any))
      detail = {} of String => JSON::Any
      if REASON_CODES.includes?(event.code) || !event.reason_code.empty?
        detail["reason"] = JSON::Any.new(event.reason_code) unless event.reason_code.empty?
        unless event.reason.empty?
          detail["notes"] = JSON.parse([{"contents" => [{"content" => event.reason}]}].to_json)
        end
      end
      detail["reported_data"] = JSON.parse(payment.to_json) if payment
      detail.empty? ? [] of Hash(String, JSON::Any) : [detail]
    end

    # --- Annuaire ----------------------------------------------------------------

    # Format d'une adresse de facturation électronique française :
    # `SIREN`, `SIREN_SIRET`, `SIREN_SUFFIXE` ou `SIREN_SIRET_CODEROUTAGE`.
    def self.address_kind(address : String) : String
      parts = address.split('_')
      siret = parts[1]?.try { |part| part.matches?(/\A\d{14}\z/) && part.starts_with?(parts[0]) } || false
      case parts.size
      when 1 then "SIREN"
      when 2 then siret ? "SIREN_SIRET" : "SIREN_SUFFIXE"
      else        siret ? "SIREN_SIRET_CODEROUTAGE" : "SIREN_SUFFIXE"
      end
    end

    # Ligne d'annuaire tirée d'un identifiant Peppol (`0225:853322915_…`,
    # `0208:0869763267`).
    def self.directory_entry(identifier : String, name : String, active : Bool?,
                             platform : String = "") : Connector::DirectoryEntry
      scheme, _, address = identifier.partition(':')
      if address.empty?
        address = scheme
        scheme = Formats::SCHEME_FR_ADDR
      end
      siren = ""
      siret = ""
      routing = ""
      if scheme == Formats::SCHEME_FR_ADDR
        parts = address.split('_')
        siren = parts[0]
        case address_kind(address)
        when "SIREN_SIRET"             then siret = parts[1]
        when "SIREN_SUFFIXE"           then routing = parts[1..].join('_')
        when "SIREN_SIRET_CODEROUTAGE" then siret, routing = parts[1], parts[2..].join('_')
        end
      end
      status = active.nil? ? "" : (active ? "active" : "inactive")
      Connector::DirectoryEntry.new(address: address, scheme: scheme, name: name, siren: siren, siret: siret,
        routing_id: routing, platform: platform, status: status)
    end

    # --- E-reporting ---------------------------------------------------------------

    # Partie d'une transaction internationale (`b2bint_contact`).
    def self.contact(party : Connector::Party) : Hash(String, String)
      contact = {"country" => party.country_code.presence || "FR"}
      if !party.siren.empty? && contact["country"] == "FR"
        contact["company_id"] = party.siren
        contact["company_id_scheme_id"] = Formats::SCHEME_SIREN
      end
      unless party.vat_number.empty?
        contact["tax_registration_id"] = party.vat_number
        contact["tax_registration_id_qualifying_id"] = "VA"
      end
      contact
    end

    # Facture internationale déclarée en e-reporting (`b2bint_invoice`) :
    # vente (`out`, le dossier vendeur) ou achat (`in`). Montants positifs,
    # l'avoir est porté par le type 381.
    def self.b2bint_invoice(entry : Connector::EReportingEntry, declarant : Connector::Party,
                            direction : String) : Hash(String, JSON::Any)
      net = entry.net.abs
      vat = entry.vat.abs
      category = category(entry, vat, net)
      counterpart = Connector::Party.new(name: entry.counterpart_name, vat_number: entry.counterpart_vat,
        country_code: entry.counterpart_country)
      seller, buyer = direction == "out" ? {declarant, counterpart} : {counterpart, declarant}
      JSON.parse({
        "direction"              => direction,
        "number"                 => entry.invoice_number,
        "issue_date"             => entry.date.to_s("%Y-%m-%d"),
        "type_code"              => entry.type_code.presence || "380",
        "currency_code"          => entry.currency_code,
        "tax_due_date_type_code" => entry.category == "goods" ? "5" : "72",
        "notes"                  => [] of String,
        "business_process"       => {"id" => business_process(entry.category), "type_id" => "urn.cpro.gouv.fr:1p0:ereporting"},
        "seller"                 => contact(seller),
        "buyer"                  => contact(buyer),
        "total"                  => {"currency_code" => entry.currency_code, "tax_amount" => Formats.amount(vat),
                    "tax_exclusive_amount" => Formats.amount(net)},
        "tax_subtotals" => [{"tax_amount" => Formats.amount(vat), "taxable_amount" => Formats.amount(net),
                             "tax_category" => category}],
      }.to_json).as_h
    end

    # Transaction B2C déclarée sans facture (`b2c_transaction`, ventes).
    def self.b2c_transaction(entry : Connector::EReportingEntry) : Hash(String, JSON::Any)
      rate = rate(entry.vat, entry.net)
      JSON.parse({
        "category_code"        => entry.category == "goods" ? "TLB1" : "TPS1",
        "currency"             => entry.currency_code,
        "date"                 => entry.date.to_s("%Y-%m-%d"),
        "role_code"            => "SE",
        "tax_exclusive_amount" => Formats.amount(entry.net),
        "tax_total"            => Formats.amount(entry.vat),
        "tax_subtotals"        => [{"tax_percent" => Formats.amount(rate), "taxable_amount" => Formats.amount(entry.net),
                             "tax_total" => Formats.amount(entry.vat)}],
      }.to_json).as_h
    end

    # Encaissement B2C déclaré sans facture (`b2c_payment`).
    def self.b2c_payment(entry : Connector::EReportingEntry) : Hash(String, JSON::Any)
      JSON.parse({
        "date"      => entry.date.to_s("%Y-%m-%d"),
        "subtotals" => [{"amount" => Formats.amount(entry.gross), "currency_code" => entry.currency_code,
                         "tax_percent" => Formats.amount(rate(entry.vat, entry.net))}],
      }.to_json).as_h
    end

    # Clé stable d'une ligne d'e-reporting (reprise idempotente).
    def self.report_key(kind : String, entry : Connector::EReportingEntry) : String
      parts = [kind, entry.invoice_number, entry.date.to_s("%Y-%m-%d"), Formats.amount(entry.gross), entry.counterpart_country]
      "report:#{Digest::SHA256.hexdigest(parts.join('|'))}"
    end

    private def self.category(entry : Connector::EReportingEntry, vat : BigDecimal, net : BigDecimal) : Hash(String, String)
      if vat.zero?
        {"code" => EU.includes?(entry.counterpart_country) ? "K" : "G", "percent" => "0.00"}
      else
        {"code" => "S", "percent" => Formats.amount(rate(vat, net))}
      end
    end

    # Taux de TVA déduit des montants (la ligne d'e-reporting n'en porte
    # qu'un), arrondi au centième.
    def self.rate(vat : BigDecimal, net : BigDecimal) : BigDecimal
      return BigDecimal.new(0) if net.zero?
      (vat.abs * 100 / net.abs).round(2, mode: :ties_away)
    end

    private def self.business_process(category : String) : String
      case category
      when "goods" then "B1"
      when "mixed" then "M1"
      else              "S1"
      end
    end

    def self.time(value : JSON::Any?) : Time?
      value.try(&.as_s?).try { |text| Time.parse_rfc3339(text) rescue nil }
    end
  end
end
