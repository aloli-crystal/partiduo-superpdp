# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Compte SUPER PDP du dossier, tel que l'API le décrit (ligne unique,
  # `key = "default"`) : mode d'authentification, environnement (bac à
  # sable ou production, *déduit des identifiants* par `GET /companies/me`,
  # ADR-004 D8), entreprise, état de la vérification (KYB), régime de TVA
  # de l'e-reporting. Les identifiants et jetons, eux, sont chiffrés dans le
  # raccordement d'EINV. Interne.
  class Account < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :key, :string, max_size: 16, unique: true, default: "default"
    # `client_credentials` ou `authorization_code`.
    field :auth_mode, :string, max_size: 24, blank: true, default: ""
    # `sandbox` ou `production` ; vide tant que l'API n'a pas répondu.
    field :env, :string, max_size: 16, blank: true, default: ""
    field :company_id, :big_int, blank: true, null: true
    field :formal_name, :string, max_size: 255, blank: true, default: ""
    field :number, :string, max_size: 32, blank: true, default: ""
    field :number_scheme, :string, max_size: 32, blank: true, default: ""
    field :country, :string, max_size: 2, blank: true, default: ""
    field :vat_regime, :string, max_size: 16, blank: true, default: ""
    field :has_vat_on_debits, :bool, default: false
    # `verified`, `needs_review`, `failed` (session OAuth), vide sinon.
    field :verification_status, :string, max_size: 16, blank: true, default: ""
    field :login_hint, :string, max_size: 255, blank: true, default: ""
    field :checked_at, :date_time, blank: true, null: true
    field :connected_at, :date_time, blank: true, null: true
    field :connected_by_id, :big_int, blank: true, null: true

    with_timestamp_fields

    def self.current : Account?
      filter(key: "default").first
    end

    def self.current! : Account
      current || new(key: "default")
    end
  end
end
