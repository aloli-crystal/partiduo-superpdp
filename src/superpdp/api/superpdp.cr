# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Contrat public de l'extension SUPERPDP, sur le modèle de
  # `Partiduo::Api` (DECISIONS C2) : acteur en premier argument, contrôle
  # d'accès en première ligne, objets de vue immuables, erreurs par champ.
  # L'interface de l'extension (`ui/bulma/`) ne voit que ce module,
  # `Einvoicing::Api` et `Partiduo::Api`.
  #
  # Tout le reste (factures, statuts, e-reporting, annuaire) passe par
  # `Einvoicing::Api`, qui appelle l'adaptateur SUPER PDP une fois le
  # dossier raccordé.
  #
  # Référence : `doc/api/superpdp.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError

    MODULE_CODE = Superpdp::CODE

    # Raccorder, vérifier et déconnecter SUPER PDP. Enregistrer ou débrancher
    # le raccordement exige en plus `einvoicing.settings.manage`, vérifiée
    # par `Einvoicing::Api` (DECISIONS D-SPDP-003).
    CONFIGURE = "superpdp.connection.manage"

    # --- État --------------------------------------------------------------------

    # État du raccordement, sans appel à la plateforme.
    def self.status(actor : Actor) : StatusView
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      row = Linking.row
      settings = row.try { |connection| Einvoicing::Connections.settings_of(connection) }
      account = Account.current
      active = Einvoicing::Connections.active
      connected = !!(active && active.adapter == ADAPTER)
      other = active && !connected ? active.adapter : nil
      auth_mode = if settings
                    settings["client_id"].empty? ? AUTHORIZATION_CODE : CLIENT_CREDENTIALS
                  else
                    account.try(&.auth_mode).presence || ""
                  end
      env = account.try(&.env) || ""
      StatusView.new(
        connected: connected, other_adapter: other, auth_mode: auth_mode, mode: env.presence || "sandbox",
        env_known: !env.empty?, client_id: settings.try(&.["client_id"]) || "",
        secret_stored: !(settings.try(&.secrets["client_secret"]?) || "").empty?,
        company_name: account.try(&.formal_name) || "", company_number: account.try(&.number) || "",
        company_number_scheme: account.try(&.number_scheme) || "", country: account.try(&.country) || "",
        vat_regime: account.try(&.vat_regime) || "", has_vat_on_debits: account.try(&.has_vat_on_debits) || false,
        verification_status: account.try(&.verification_status) || "", checked_at: account.try(&.checked_at),
        connected_at: connected ? account.try(&.connected_at) : nil, last_sync_at: row.try(&.last_sync_at),
        last_error: row.try(&.last_error) || "", authorization_available: Config.authorization_code?,
      )
    end

    # Valeurs proposées pour lancer le mode _authorization code_ : numéro
    # d'entreprise du dossier (SIREN en France, numéro d'entreprise en
    # Belgique) et son schéma.
    def self.authorization_defaults(actor : Actor, redirect_uri : String, login_hint : String = "") : AuthorizationInput
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      settings = Partiduo::Api::Core.settings(Actor.system)
      number, scheme = if settings.tax_regime == "be"
                         {(settings.vat_number.gsub(/\D/, "").presence || settings.siren.gsub(/\D/, "")), "be_numero_entreprise"}
                       else
                         {settings.siren.gsub(/\D/, ""), "fr_siren"}
                       end
      AuthorizationInput.new(redirect_uri: redirect_uri, login_hint: login_hint.presence || settings.email,
        company_number: number, company_number_scheme: number.empty? ? "" : scheme)
    rescue Partiduo::Api::NotFound
      AuthorizationInput.new(redirect_uri: redirect_uri, login_hint: login_hint)
    end

    # --- Raccordement ------------------------------------------------------------

    # Mode _client credentials_ : identifiants d'une application SUPER PDP
    # de la société, essayés avant d'être enregistrés (chiffrés) ; SUPER PDP
    # devient l'adaptateur actif d'EINV. Le mode bac à sable ou production
    # est celui de ces identifiants.
    def self.connect_credentials(actor : Actor, input : CredentialsInput) : Result(StatusView)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      result = Linking.connect_credentials(actor, input)
      result.failure? ? Result(StatusView).failure(result.errors) : Result(StatusView).success(status(actor))
    end

    # Mode _authorization code_ : adresse du parcours d'inscription SUPER
    # PDP (vérification d'identité et d'entreprise), pré-rempli, avec
    # `state` anti-CSRF et défi PKCE ; l'utilisateur y est redirigé.
    def self.start_authorization(actor : Actor, input : AuthorizationInput) : Result(AuthorizationView)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      Linking.start(actor, input)
    end

    # Retour du parcours sur l'instance : `state` contrôlé, code échangé
    # (PKCE) contre un jeton d'accès et un jeton de rafraîchissement,
    # enregistrés chiffrés ; SUPER PDP devient l'adaptateur actif d'EINV.
    def self.complete_authorization(actor : Actor, input : CallbackInput) : Result(StatusView)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      result = Linking.complete(actor, input)
      result.failure? ? Result(StatusView).failure(result.errors) : Result(StatusView).success(status(actor))
    end

    # Vérifie le raccordement auprès de SUPER PDP (jeton, session,
    # entreprise) et met à jour l'entreprise et le mode.
    def self.check(actor : Actor) : Result(StatusView)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      connector = Linking.connector
      return Result(StatusView).failure(FieldError.base("superpdp.errors.connection.missing")) if connector.nil?
      connector.check
      Result(StatusView).success(status(actor))
    rescue ex : NotVerified
      Result(StatusView).failure(FieldError.base("superpdp.errors.connection.not_verified",
        {"status" => ex.verification}))
    rescue ex : AuthorizationRequired
      Result(StatusView).failure(FieldError.base("superpdp.errors.connection.authorization", {"detail" => ex.message.to_s}))
    rescue ex : Einvoicing::ConnectorError
      Result(StatusView).failure(FieldError.base("superpdp.errors.connection.failed", {"detail" => ex.message.to_s}))
    end

    # Déconnexion : jetons révoqués (RFC 7009) puis EINV débranché.
    def self.disconnect(actor : Actor) : Result(Nil)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      Linking.disconnect(actor)
    end

    # Lignes d'annuaire de l'entreprise chez SUPER PDP (appel à la
    # plateforme).
    def self.directory_lines(actor : Actor) : Result(Array(DirectoryLineView))
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      connector = Linking.connector
      return Result(Array(DirectoryLineView)).failure(FieldError.base("superpdp.errors.connection.missing")) if connector.nil?
      lines = connector.directory_entries.map do |line|
        identifier = line["identifier"]?.try(&.as_s?) || ""
        scheme, _, address = identifier.partition(':')
        address, scheme = scheme, "" if address.empty?
        kind = scheme == Einvoicing::Formats::SCHEME_FR_ADDR ? Mapping.address_kind(address.rchop("_replyto")) : ""
        DirectoryLineView.new(identifier: identifier, scheme: scheme, address: address, kind: kind,
          directory: line["directory"]?.try(&.as_s?) || "", status: line["status"]?.try(&.as_s?) || "",
          reply_to: line["is_replyto"]?.try(&.as_bool?) || false)
      end
      Result(Array(DirectoryLineView)).success(lines)
    rescue ex : Einvoicing::ConnectorError
      Result(Array(DirectoryLineView)).failure(FieldError.base("superpdp.errors.connection.failed", {"detail" => ex.message.to_s}))
    end

    # Régime de TVA de l'entreprise chez SUPER PDP : il fixe le calendrier
    # de l'e-reporting, que SUPER PDP refuse tant qu'il n'est pas choisi.
    def self.update_vat_regime(actor : Actor, input : VatRegimeInput) : Result(StatusView)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      unless VAT_REGIMES.includes?(input.vat_regime)
        return Result(StatusView).failure(FieldError.new("vat_regime", "superpdp.errors.vat_regime.invalid",
          {"value" => input.vat_regime}))
      end
      connector = Linking.connector
      return Result(StatusView).failure(FieldError.base("superpdp.errors.connection.missing")) if connector.nil?
      connector.update_vat_regime(input.vat_regime, input.has_vat_on_debits)
      Account.current.try do |account|
        account.vat_regime = input.vat_regime
        account.has_vat_on_debits = input.has_vat_on_debits
        account.save!
      end
      Result(StatusView).success(status(actor))
    rescue ex : Einvoicing::ConnectorError
      Result(StatusView).failure(FieldError.base("superpdp.errors.connection.failed", {"detail" => ex.message.to_s}))
    end
  end
end
