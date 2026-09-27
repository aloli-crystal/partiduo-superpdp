# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  module Api
    # Modes d'authentification OAuth 2.1 (ADR-004 D8). Libellé :
    # `superpdp.auth_modes.<code>`.
    AUTH_MODES = [CLIENT_CREDENTIALS, AUTHORIZATION_CODE]

    # Schémas du numéro d'entreprise pré-rempli dans le parcours
    # d'inscription SUPER PDP. Libellé : `superpdp.schemes.<code>`.
    SCHEMES = OAuth::SCHEMES

    # Régimes de TVA de l'entreprise chez SUPER PDP (calendrier de
    # l'e-reporting). Libellé : `superpdp.vat_regimes.<code>`.
    VAT_REGIMES = %w[monthly quarterly simplified vat_exemption]

    # États de la vérification de l'entreprise (KYB). Libellé :
    # `superpdp.verification.<code>`.
    VERIFICATION_STATUSES = %w[verified needs_review failed]

    # Formats d'adresse de facturation électronique. Libellé :
    # `superpdp.address_kinds.<code>`.
    ADDRESS_KINDS = %w[SIREN SIREN_SIRET SIREN_SUFFIXE SIREN_SIRET_CODEROUTAGE]

    # État du raccordement SUPER PDP du dossier. `mode` : `sandbox` ou
    # `production`, déduit des identifiants et toujours affiché (ADR-004
    # D8). `other_adapter` : un autre adaptateur d'EINV est actif.
    record StatusView,
      connected : Bool,
      other_adapter : String?,
      auth_mode : String,
      mode : String,
      env_known : Bool,
      client_id : String,
      secret_stored : Bool,
      company_name : String,
      company_number : String,
      company_number_scheme : String,
      country : String,
      vat_regime : String,
      has_vat_on_debits : Bool,
      verification_status : String,
      checked_at : Time?,
      connected_at : Time?,
      last_sync_at : Time?,
      last_error : String,
      authorization_available : Bool do
      def mode_key : String
        "superpdp.modes.#{mode}"
      end

      def auth_mode_key : String
        "superpdp.auth_modes.#{auth_mode}"
      end

      def verified? : Bool
        verification_status.empty? || verification_status == "verified"
      end
    end

    # Identifiants d'une application SUPER PDP de la société (mode _client
    # credentials_) ; un secret laissé vide garde celui enregistré.
    record CredentialsInput, client_id : String, client_secret : String

    # Lancement du mode _authorization code_ : courriel (`login_hint`),
    # numéro d'entreprise et son schéma, adresse de retour de l'instance.
    record AuthorizationInput,
      redirect_uri : String,
      login_hint : String = "",
      company_number : String = "",
      company_number_scheme : String = ""

    # Adresse du parcours d'autorisation SUPER PDP vers laquelle rediriger.
    record AuthorizationView, url : String

    # Retour du parcours d'autorisation (paramètres de la route de rappel).
    record CallbackInput, state : String, code : String = "", error : String = "", error_description : String = ""

    record VatRegimeInput, vat_regime : String, has_vat_on_debits : Bool = false

    # Ligne d'annuaire de l'entreprise chez SUPER PDP : identifiant Peppol
    # (`0225:SIREN…`, `0208:…`), adresse et son format, annuaire (`ppf`,
    # `peppol`), état (`pending`, `created`, `error`), adresse technique de
    # réponse (`_replyto`).
    record DirectoryLineView,
      identifier : String,
      scheme : String,
      address : String,
      kind : String,
      directory : String,
      status : String,
      reply_to : Bool
  end
end
