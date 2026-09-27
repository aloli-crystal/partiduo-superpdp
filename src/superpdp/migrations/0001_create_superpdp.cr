# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension SUPERPDP (ADR-004 D8) : compte SUPER PDP du
# dossier, demandes d'autorisation OAuth en cours, factures connues de la
# plateforme (sens, reprise idempotente des dépôts), messages envoyés
# (statuts, e-reporting).
#
# Intégrité en base : une seule ligne de compte ; modes, environnements,
# sens, états et natures contrôlés ; une facture déposée a son identifiant
# chez la plateforme ; un message envoyé aussi.
class Migration::Superpdp::V0001 < Marten::Migration
  depends_on :einvoicing, "0001_create_einvoicing"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE superpdp_account
        ADD CONSTRAINT superpdp_account_key_check CHECK (key = 'default'),
        ADD CONSTRAINT superpdp_account_auth_mode_check CHECK (auth_mode IN ('', 'client_credentials', 'authorization_code')),
        ADD CONSTRAINT superpdp_account_env_check CHECK (env IN ('', 'sandbox', 'production'))
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE superpdp_invoice_ref
        ADD CONSTRAINT superpdp_invoice_ref_direction_check CHECK (direction IN ('in', 'out')),
        ADD CONSTRAINT superpdp_invoice_ref_state_check CHECK (state IN ('pending', 'created')),
        ADD CONSTRAINT superpdp_invoice_ref_created_check CHECK (state = 'pending' OR platform_id IS NOT NULL)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE superpdp_sent_message
        ADD CONSTRAINT superpdp_sent_message_kind_check CHECK (kind IN
          ('event', 'b2bint_invoice', 'b2c_transaction', 'b2c_payment')),
        ADD CONSTRAINT superpdp_sent_message_state_check CHECK (state IN ('pending', 'sent')),
        ADD CONSTRAINT superpdp_sent_message_sent_check CHECK (state = 'pending' OR platform_id IS NOT NULL)
      SQL
  ]

  def plan
    create_table :superpdp_account do
      column :id, :big_int, primary_key: true, auto: true
      column :key, :string, max_size: 16, unique: true, default: "default"
      column :auth_mode, :string, max_size: 24, default: ""
      column :env, :string, max_size: 16, default: ""
      column :company_id, :big_int, null: true
      column :formal_name, :string, max_size: 255, default: ""
      column :number, :string, max_size: 32, default: ""
      column :number_scheme, :string, max_size: 32, default: ""
      column :country, :string, max_size: 2, default: ""
      column :vat_regime, :string, max_size: 16, default: ""
      column :has_vat_on_debits, :bool, default: false
      column :verification_status, :string, max_size: 16, default: ""
      column :login_hint, :string, max_size: 255, default: ""
      column :checked_at, :date_time, null: true
      column :connected_at, :date_time, null: true
      column :connected_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :superpdp_authorization do
      column :id, :big_int, primary_key: true, auto: true
      column :state_digest, :string, max_size: 64, unique: true
      column :code_verifier, :text
      column :redirect_uri, :string, max_size: 2000
      column :login_hint, :string, max_size: 255, default: ""
      column :company_number, :string, max_size: 32, default: ""
      column :company_number_scheme, :string, max_size: 32, default: ""
      column :user_id, :big_int, null: true
      column :expires_at, :date_time
      column :used_at, :date_time, null: true
      column :created_at, :date_time
    end

    create_table :superpdp_invoice_ref do
      column :id, :big_int, primary_key: true, auto: true
      column :platform_id, :big_int, null: true, unique: true
      column :direction, :string, max_size: 3
      column :external_id, :string, max_size: 36, null: true, unique: true
      column :state, :string, max_size: 16, default: "created"
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :superpdp_sent_message do
      column :id, :big_int, primary_key: true, auto: true
      column :key, :string, max_size: 128, unique: true
      column :kind, :string, max_size: 24
      column :platform_id, :big_int, null: true, index: true
      column :state, :string, max_size: 16, default: "pending"
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
