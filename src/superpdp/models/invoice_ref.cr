# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Facture connue de SUPER PDP : son identifiant chez la plateforme et son
  # sens (`in` reçue, `out` émise). Sert à deux choses :
  #
  # * le sens d'un statut lu par `GET /invoice_events`, qui ne cite que
  #   l'identifiant de la facture ;
  # * la reprise idempotente d'un dépôt : l'`external_id` est noté *avant*
  #   l'envoi (`state = "pending"`) ; une reprise après une réponse perdue
  #   cherche d'abord la facture chez la plateforme au lieu de la déposer
  #   deux fois.
  #
  # Interne.
  class InvoiceRef < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :platform_id, :big_int, blank: true, null: true, unique: true
    field :direction, :string, max_size: 3
    field :external_id, :string, max_size: 36, blank: true, null: true, unique: true
    field :state, :string, max_size: 16, default: "created"

    with_timestamp_fields
  end
end
