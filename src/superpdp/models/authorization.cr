# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Demande d'autorisation OAuth en cours (mode _authorization code_,
  # ADR-004 D8) : l'empreinte du `state` anti-CSRF, le vérificateur PKCE
  # chiffré, l'adresse de retour, l'utilisateur qui l'a lancée. À usage
  # unique, valable dix minutes. Interne.
  class Authorization < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    # SHA-256 du `state` : la valeur elle-même ne quitte que le navigateur.
    field :state_digest, :string, max_size: 64, unique: true
    # Vérificateur PKCE (RFC 7636), chiffré (`Einvoicing::Secrets`).
    field :code_verifier, :text
    field :redirect_uri, :string, max_size: 2000
    field :login_hint, :string, max_size: 255, blank: true, default: ""
    field :company_number, :string, max_size: 32, blank: true, default: ""
    field :company_number_scheme, :string, max_size: 32, blank: true, default: ""
    field :user_id, :big_int, blank: true, null: true
    field :expires_at, :date_time
    field :used_at, :date_time, blank: true, null: true
    field :created_at, :date_time
  end
end
