# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Message envoyé à SUPER PDP par le dossier (statut du cycle de vie,
  # donnée d'e-reporting), noté *avant* l'envoi sous une clé stable :
  #
  # * une reprise après une réponse perdue (`state = "pending"`) vérifie
  #   chez la plateforme si le message existe déjà (reprise idempotente) ;
  # * un message déjà `sent` n'est jamais renvoyé ;
  # * les statuts que le dossier a lui-même émis réapparaissent dans
  #   `GET /invoice_events` : leur identifiant (`platform_id`) permet de ne
  #   pas les relire comme des statuts reçus.
  #
  # `kind` : `event`, `b2bint_invoice`, `b2c_transaction`, `b2c_payment`.
  # Interne.
  class SentMessage < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :key, :string, max_size: 128, unique: true
    field :kind, :string, max_size: 24
    field :platform_id, :big_int, blank: true, null: true, index: true
    field :state, :string, max_size: 16, default: "pending"

    with_timestamp_fields
  end
end
