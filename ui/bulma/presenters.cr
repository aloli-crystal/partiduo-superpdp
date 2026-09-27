# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  module Ui
    # Ligne présentée à un gabarit : textes déjà mis en forme, par nom
    # (un grand `Hash` n'est pas lu par les gabarits Marten, BLOCAGES
    # B-EINV-001).
    class Row
      include Marten::Template::Object

      getter values : Hash(String, String?)

      def initialize(@values : Hash(String, String?))
      end

      def [](key : String) : String?
        values[key]?
      end

      def resolve_template_attribute(key : String)
        values[key]?
      end
    end

    def self.row(values : Hash(String, String?)) : Row
      Row.new(values)
    end

    def self.url(name : String) : String
      Marten.routes.reverse("superpdp:#{name}")
    end

    # Présentation de l'état du raccordement.
    module Present
      alias Api = Superpdp::Api

      def self.status(view : Api::StatusView, fmt : PartiduoUi::Format) : Row
        Ui.row({
          "connected"      => view.connected ? "1" : nil,
          "mode"           => view.mode,
          "mode_label"     => I18n.t(view.mode_key),
          "env_known"      => view.env_known ? "1" : nil,
          "auth_mode"      => view.auth_mode.presence,
          "auth_label"     => view.auth_mode.empty? ? nil : I18n.t(view.auth_mode_key),
          "client_id"      => view.client_id,
          "secret_stored"  => view.secret_stored ? "1" : nil,
          "company"        => view.company_name.presence,
          "number"         => view.company_number.presence,
          "scheme"         => view.company_number_scheme.presence.try { |code| I18n.t("superpdp.schemes.#{code}") },
          "verification"   => view.verification_status.presence,
          "verified"       => view.verified? ? "1" : nil,
          "verification_l" => view.verification_status.presence.try { |code| I18n.t("superpdp.verification.#{code}") },
          "vat_regime"     => view.vat_regime.presence,
          "vat_regime_l"   => view.vat_regime.presence.try { |code| I18n.t("superpdp.vat_regimes.#{code}") },
          "on_debits"      => view.has_vat_on_debits ? "1" : nil,
          "checked_at"     => view.checked_at.try { |time| fmt.datetime(time) },
          "connected_at"   => view.connected_at.try { |time| fmt.datetime(time) },
          "last_sync"      => view.last_sync_at.try { |time| fmt.datetime(time) },
          "last_error"     => view.last_error.presence,
          "other_adapter"  => view.other_adapter,
        })
      end

      def self.line(view : Api::DirectoryLineView) : Row
        Ui.row({
          "identifier" => view.identifier,
          "scheme"     => view.scheme,
          "address"    => view.address,
          "kind"       => view.kind.presence.try { |code| I18n.t("superpdp.address_kinds.#{code}") },
          "directory"  => view.directory,
          "status"     => view.status,
          "reply_to"   => view.reply_to ? "1" : nil,
        })
      end
    end
  end
end
