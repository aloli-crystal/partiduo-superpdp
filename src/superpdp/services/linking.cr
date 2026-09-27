# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Raccordement du dossier à SUPER PDP (ADR-004 D8) : essai des
  # identifiants avant de les enregistrer, parcours _authorization code_
  # (state, PKCE), enregistrement dans EINV (`Einvoicing::Api.configure`,
  # secrets et jetons chiffrés), révocation à la déconnexion. Interne ; les
  # écrans passent par `Superpdp::Api`.
  module Linking
    alias Connections = Einvoicing::Connections
    alias FieldError = Partiduo::Api::FieldError
    alias Result = Partiduo::Api::Result

    # Raccordement EINV de SUPER PDP, actif ou non.
    def self.row : Einvoicing::Connection?
      Einvoicing::Connection.filter(adapter: ADAPTER).first
    end

    def self.active? : Bool
      Connections.active.try(&.adapter) == ADAPTER
    end

    # Connecteur du raccordement SUPER PDP enregistré (actif ou non).
    def self.connector : Connector?
      row.try { |connection| Connector.new(Connections.settings_of(connection)) }
    end

    # Mode _client credentials_ : essai des identifiants (jeton, session,
    # entreprise), puis enregistrement.
    def self.connect_credentials(actor : Partiduo::Api::Actor, input : Api::CredentialsInput) : Result(Nil)
      client_id = input.client_id.strip
      secret = input.client_secret.strip
      stored = row.try { |connection| Connections.settings_of(connection) }
      if secret.empty? && stored && stored["client_id"] == client_id
        secret = stored["client_secret"]
      end
      errors = [] of FieldError
      errors << FieldError.new("client_id", "superpdp.errors.credentials.blank") if client_id.empty?
      errors << FieldError.new("client_secret", "superpdp.errors.credentials.blank") if secret.empty?
      if client_id.size > 200 || secret.size > 200
        errors << FieldError.new("client_id", "superpdp.errors.credentials.too_long", {"max" => "200"})
      end
      return Result(Nil).failure(errors) unless errors.empty?

      store = MemoryStore.new
      probe = begin
        Connector.new(Client.new(Credentials.new(client_id, secret, CLIENT_CREDENTIALS), store)).probe
      rescue AuthorizationRequired
        return Result(Nil).failure(FieldError.new("client_secret", "superpdp.errors.credentials.refused"))
      rescue ex : Einvoicing::ConnectorError
        return Result(Nil).failure(FieldError.base("superpdp.errors.connection.failed", {"detail" => ex.message.to_s}))
      end
      save(actor, {"client_id" => client_id, "client_secret" => secret}, store, CLIENT_CREDENTIALS, probe, "")
    end

    # Mode _authorization code_ : demande d'autorisation (state anti-CSRF,
    # PKCE), adresse du parcours SUPER PDP.
    def self.start(actor : Partiduo::Api::Actor, input : Api::AuthorizationInput) : Result(Api::AuthorizationView)
      unless Config.authorization_code?
        return Result(Api::AuthorizationView).failure(FieldError.base("superpdp.errors.authorization.unavailable"))
      end
      redirect = Config.redirect_uri_override || input.redirect_uri.strip
      login = input.login_hint.strip
      number = input.company_number.gsub(/[\s.]/, "")
      scheme = number.empty? ? "" : input.company_number_scheme.strip
      errors = [] of FieldError
      errors << FieldError.new("redirect_uri", "superpdp.errors.authorization.redirect_uri") unless redirect_uri?(redirect)
      if !login.empty? && (login.size > 255 || !login.matches?(/\A[^@\s]+@[^@\s]+\z/))
        errors << FieldError.new("login_hint", "superpdp.errors.authorization.login_hint")
      end
      unless number.empty? || valid_number?(number, scheme)
        errors << FieldError.new("company_number", "superpdp.errors.authorization.company_number",
          {"value" => number, "scheme" => scheme})
      end
      return Result(Api::AuthorizationView).failure(errors) unless errors.empty?

      # Les demandes expirées ne servent plus à rien.
      Authorization.filter(expires_at__lt: Time.utc - 1.day).delete
      state = OAuth.state
      pkce = OAuth.pkce
      Authorization.create!(state_digest: OAuth.digest(state), code_verifier: Einvoicing::Secrets.encrypt(pkce.verifier),
        redirect_uri: redirect, login_hint: login, company_number: number, company_number_scheme: scheme,
        user_id: actor.user_id, expires_at: Time.utc + OAuth::LIFETIME, created_at: Time.utc)
      url = OAuth.authorize_url(Config.operator_client_id, redirect, state, pkce.challenge, login, number, scheme)
      Result(Api::AuthorizationView).success(Api::AuthorizationView.new(url))
    end

    # Retour du parcours : contrôle du `state` (connu, non expiré, à usage
    # unique, lancé par le même utilisateur), échange du code avec le
    # vérificateur PKCE, puis enregistrement.
    def self.complete(actor : Partiduo::Api::Actor, input : Api::CallbackInput) : Result(Nil)
      request = Authorization.filter(state_digest: OAuth.digest(input.state), used_at: nil).first
      if input.state.empty? || request.nil? || request.expires_at! < Time.utc || request.user_id != actor.user_id
        return Result(Nil).failure(FieldError.base("superpdp.errors.authorization.state"))
      end
      # À usage unique, même en cas d'échec.
      updated = Authorization.filter(id: request.id, used_at: nil).update(used_at: Time.utc)
      return Result(Nil).failure(FieldError.base("superpdp.errors.authorization.state")) if updated.zero?
      unless input.error.empty?
        return Result(Nil).failure(FieldError.base("superpdp.errors.authorization.denied",
          {"detail" => [input.error, input.error_description].reject(&.empty?).join(" : ")[0, 300]}))
      end
      return Result(Nil).failure(FieldError.base("superpdp.errors.authorization.code")) if input.code.empty?

      store = MemoryStore.new
      client = Client.new(Credentials.new(Config.operator_client_id, Config.operator_client_secret, AUTHORIZATION_CODE), store)
      probe = begin
        client.exchange_code(input.code, Einvoicing::Secrets.decrypt(request.code_verifier.to_s), request.redirect_uri.to_s)
        Connector.new(client).probe
      rescue ex : AuthorizationRequired
        return Result(Nil).failure(FieldError.base("superpdp.errors.authorization.exchange", {"detail" => ex.message.to_s}))
      rescue ex : Einvoicing::ConnectorError
        return Result(Nil).failure(FieldError.base("superpdp.errors.connection.failed", {"detail" => ex.message.to_s}))
      end
      if store.refresh_token.nil?
        return Result(Nil).failure(FieldError.base("superpdp.errors.authorization.exchange",
          {"detail" => "pas de jeton de rafraîchissement"}))
      end
      save(actor, {"client_id" => "", "client_secret" => ""}, store, AUTHORIZATION_CODE, probe, request.login_hint.to_s)
    end

    # Déconnexion : révocation des jetons (RFC 7009), puis EINV débranche
    # la plateforme. Les identifiants d'une application de la société
    # restent enregistrés (chiffrés) pour se raccorder de nouveau.
    def self.disconnect(actor : Partiduo::Api::Actor) : Result(Nil)
      revoked = connector.try(&.revoke)
      Einvoicing::Api.disconnect(actor) if active?
      Account.current.try do |account|
        account.connected_at = nil
        account.save!
      end
      Log.info { "SUPER PDP déconnecté (révocation #{revoked ? "acceptée" : "non confirmée"})" }
      Result(Nil).success(nil)
    end

    # Enregistre le raccordement dans EINV (adaptateur actif du dossier),
    # les jetons obtenus et l'entreprise ; révoque l'autorisation
    # précédente si l'on change de mode ou de compte.
    private def self.save(actor : Partiduo::Api::Actor, values : Hash(String, String), store : MemoryStore,
                          auth_mode : String, probe : Connector::Probe, login_hint : String) : Result(Nil)
      connector.try do |previous|
        previous.revoke if previous.client.store.refresh_token
      end
      result = Einvoicing::Api.configure(actor, Einvoicing::Api::ConnectionInput.new(ADAPTER, values))
      return Result(Nil).failure(result.errors) if result.failure?
      if (connection = row) && (access = store.current_access) && (expires = store.expires_at)
        settings = Connections.settings_of(connection)
        settings.store_tokens(access, expires, store.refresh_token || (auth_mode == CLIENT_CREDENTIALS ? "" : nil))
      end
      account = probe.save(auth_mode, actor.user_id, connected: true)
      account.login_hint = login_hint
      account.save!
      Result(Nil).success(nil)
    end

    # Adresse de retour admise : HTTPS, ou HTTP sur un hôte de
    # développement (`localhost`, `*.localhost`, `127.0.0.1`).
    def self.redirect_uri?(value : String) : Bool
      uri = URI.parse(value) rescue nil
      return false if uri.nil? || uri.host.to_s.empty? || value.size > 2000
      return true if uri.scheme == "https"
      host = uri.host.to_s
      uri.scheme == "http" && (host == "localhost" || host.ends_with?(".localhost") || host == "127.0.0.1")
    end

    # Numéro d'entreprise selon son schéma : SIREN (9 chiffres, clé de
    # Luhn), numéro d'entreprise belge (10 chiffres, modulo 97), numéro
    # fictif du bac à sable.
    def self.valid_number?(number : String, scheme : String) : Bool
      case scheme
      when "fr_siren"
        number.matches?(/\A\d{9}\z/) && luhn?(number)
      when "be_numero_entreprise"
        number.matches?(/\A[01]\d{9}\z/) && 97 - number[0, 8].to_i64 % 97 == number[8, 2].to_i64
      when "sandbox"
        number.matches?(/\A\d{1,32}\z/)
      else
        false
      end
    end

    private def self.luhn?(digits : String) : Bool
      sum = digits.reverse.each_char.with_index.sum do |char, index|
        digit = char.to_i
        digit = digit * 2 - (digit * 2 > 9 ? 9 : 0) if index.odd?
        digit
      end
      sum % 10 == 0
    end

    Log = ::Log.for("superpdp")
  end
end
