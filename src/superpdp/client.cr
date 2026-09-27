# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "uri"

module Superpdp
  alias Http = Einvoicing::Http

  # Identifiants OAuth 2.1 d'un raccordement : ceux de la société (mode
  # `client_credentials`) ou ceux de l'application de l'opérateur (mode
  # `authorization_code`, jeton de rafraîchissement propre à la société).
  record Credentials, client_id : String, client_secret : String, grant : String do
    def client_credentials? : Bool
      grant == CLIENT_CREDENTIALS
    end
  end

  CLIENT_CREDENTIALS = "client_credentials"
  AUTHORIZATION_CODE = "authorization_code"

  # Où lire et ranger les jetons d'un raccordement.
  abstract class TokenStore
    # Jeton d'accès encore valable (une minute de marge), `nil` sinon.
    abstract def access_token : String?
    abstract def refresh_token : String?
    # Range un jeton d'accès et, s'il est donné, le nouveau jeton de
    # rafraîchissement (rotation : il remplace l'ancien).
    abstract def store(access : String, expires_at : Time, refresh : String?) : Nil
    abstract def clear_access : Nil
    abstract def clear_refresh : Nil

    # Exécute le bloc en exclusion mutuelle avec les autres processus de
    # l'instance : le renouvellement d'un jeton de rafraîchissement ne doit
    # être fait qu'une fois (OAuth 2.1 : un jeton déjà servi est refusé).
    def synchronize(&) : Nil
      yield
    end
  end

  # Jetons du raccordement EINV (chiffrés en base par
  # `Einvoicing::Connections::Settings`).
  class SettingsStore < TokenStore
    # Clé du verrou consultatif PostgreSQL du renouvellement.
    LOCK_KEY = 0x5355504552504450_i64 # "SUPERPDP"

    def initialize(@settings : Einvoicing::Connections::Settings)
    end

    def access_token : String?
      @settings.access_token
    end

    def refresh_token : String?
      @settings.refresh_token
    end

    def store(access : String, expires_at : Time, refresh : String?) : Nil
      @settings.store_tokens(access, expires_at, refresh)
    end

    def clear_access : Nil
      @settings.clear_tokens
    end

    def clear_refresh : Nil
      @settings.store_tokens("", Time.utc, "")
    end

    def synchronize(&) : Nil
      connection = Marten::DB::Connection.default
      connection.transaction do
        connection.open { |db| db.exec("SELECT pg_advisory_xact_lock($1)", LOCK_KEY) }
        yield
      end
      nil
    end
  end

  # Jetons en mémoire : essai d'identifiants avant de les enregistrer,
  # suite d'intégration.
  class MemoryStore < TokenStore
    @access : String?
    @expires_at : Time?
    @refresh : String?

    def initialize(@refresh : String? = nil)
    end

    # Échéance du jeton d'accès en cours.
    def expires_at : Time?
      @expires_at
    end

    # Jeton d'accès en cours, même proche de l'échéance.
    def current_access : String?
      @access
    end

    def access_token : String?
      expires = @expires_at
      return if expires.nil? || expires - 60.seconds < Time.utc
      @access
    end

    def refresh_token : String?
      @refresh
    end

    def store(access : String, expires_at : Time, refresh : String?) : Nil
      @access = access
      @expires_at = expires_at
      @refresh = refresh.presence if refresh
    end

    def clear_access : Nil
      @access = nil
      @expires_at = nil
    end

    def clear_refresh : Nil
      @refresh = nil
    end
  end

  # Échanges authentifiés avec l'API JSON SUPER PDP
  # (`https://api.superpdp.tech/v1.beta/`), par le transport d'EINV (TLS
  # vérifié, plateforme simulée dans les specs).
  #
  # * Jeton d'accès OAuth 2.1 obtenu à la demande et renouvelé
  #   automatiquement à l'expiration (30 minutes) ou sur un refus 401 (une
  #   seule nouvelle tentative).
  # * Mode `authorization_code` : le jeton de rafraîchissement est
  #   *renouvelé à chaque usage* ; le nouveau remplace l'ancien, chiffré,
  #   sous un verrou PostgreSQL pour qu'un seul processus le serve.
  # * Erreurs (page « Erreurs ») : réponse `http_ko` (`http_status_code`,
  #   `code`, `message`) levée en `ApiError` ; 429 et 503 (requête non
  #   traitée) rejoués après un délai ; une coupure réseau n'est rejouée que
  #   pour une lecture (`GET`).
  class Client
    getter credentials : Credentials
    getter store : TokenStore

    def initialize(@credentials : Credentials, @store : TokenStore)
    end

    # --- Requêtes de l'API ---------------------------------------------------

    def get_json(path : String, params : URI::Params? = nil) : JSON::Any
      parse(ensure_success!(call("GET", url(path, params))))
    end

    # Fichier brut (facture originale) : rend le corps et son type.
    def get_bytes(path : String, params : URI::Params? = nil, accept : String = "*/*") : {Bytes, String}
      response = ensure_success!(call("GET", url(path, params), accept: accept))
      {response.body, response.headers["content-type"]? || ""}
    end

    def post_json(path : String, body : String, params : URI::Params? = nil) : JSON::Any
      parse(ensure_success!(call("POST", url(path, params), body.to_slice, "application/json")))
    end

    def patch_json(path : String, body : String) : JSON::Any
      parse(ensure_success!(call("PATCH", url(path, nil), body.to_slice, "application/json")))
    end

    # Dépôt d'un fichier (PDF Factur-X, XML CII ou UBL) en corps brut.
    def post_file(path : String, params : URI::Params?, content : Bytes, content_type : String) : JSON::Any
      parse(ensure_success!(call("POST", url(path, params), content, content_type)))
    end

    # Requête sans authentification (validateur public).
    def post_public(path : String, body : Bytes, content_type : String) : JSON::Any
      response = Http.exec("POST", Config.api_url(path), {"Content-Type" => content_type, "Accept" => "application/json"}, body)
      parse(ensure_success!(response))
    end

    # --- OAuth 2.1 -------------------------------------------------------------

    # Jeton d'accès valable : celui conservé, sinon un nouveau (client
    # credentials, ou jeton de rafraîchissement renouvelé sous verrou).
    def token : String
      if current = store.access_token
        return current
      end
      if credentials.client_credentials?
        request_token({"grant_type" => "client_credentials"})
      else
        refreshed = nil
        begin
          store.synchronize do
            # Un autre processus a pu renouveler pendant l'attente du verrou.
            refreshed = store.access_token || refresh!
          end
        rescue ex : RefreshRefused
          # Hors de la transaction du verrou, annulée par l'exception : le
          # jeton refusé ne resservira pas.
          store.clear_refresh
          raise ex
        end
        refreshed || raise AuthorizationRequired.new("jeton SUPER PDP non obtenu")
      end
    end

    # Échange un code d'autorisation contre les jetons (PKCE, RFC 7636).
    def exchange_code(code : String, verifier : String, redirect_uri : String) : Nil
      request_token({"grant_type" => "authorization_code", "code" => code, "code_verifier" => verifier,
                     "redirect_uri" => redirect_uri})
      nil
    end

    # Révoque un jeton (RFC 7009) ; `true` si la plateforme l'a accepté.
    # Une révocation qui échoue n'empêche jamais la déconnexion.
    def revoke(token : String, hint : String) : Bool
      return true if token.empty?
      fields = {"token" => token, "token_type_hint" => hint, "client_id" => credentials.client_id,
                "client_secret" => credentials.client_secret}
      response = Http.exec("POST", Config.oauth_url(Config::REVOKE_PATH), form_headers, Http.form(fields))
      response.success?
    rescue Einvoicing::ConnectorError
      false
    end

    private def refresh! : String
      refresh = store.refresh_token.presence
      raise AuthorizationRequired.new("aucune autorisation SUPER PDP : raccordez la plateforme") if refresh.nil?
      request_token({"grant_type" => "refresh_token", "refresh_token" => refresh})
    end

    private def request_token(fields : Hash(String, String)) : String
      fields["client_id"] = credentials.client_id
      fields["client_secret"] = credentials.client_secret
      response = Http.exec("POST", Config.oauth_url(Config::TOKEN_PATH), form_headers, Http.form(fields))
      unless response.success?
        error = oauth_error(response)
        if response.status >= 500
          raise ApiError.new(response.status, error)
        end
        message = "autorisation SUPER PDP refusée (#{response.status} #{error})".strip
        # Jeton de rafraîchissement refusé (expiré, révoqué, déjà servi).
        raise RefreshRefused.new(message) if fields["grant_type"] == "refresh_token" && error.includes?("invalid_grant")
        raise AuthorizationRequired.new(message)
      end
      json = parse(response)
      access = json["access_token"]?.try(&.as_s?).presence || raise ApiError.new(response.status, "réponse OAuth sans access_token")
      expires = json["expires_in"]?.try { |value| value.as_i64? || value.as_s?.try(&.to_i64?) } || 1800_i64
      store.store(access, Time.utc + expires.seconds, json["refresh_token"]?.try(&.as_s?).presence)
      access
    end

    private def oauth_error(response : Http::Response) : String
      json = JSON.parse(response.text)
      [json["error"]?.try(&.as_s?), json["error_description"]?.try(&.as_s?)].compact.join(" : ")
    rescue JSON::ParseException
      ""
    end

    private def form_headers : Hash(String, String)
      {"Content-Type" => "application/x-www-form-urlencoded", "Accept" => "application/json"}
    end

    # --- Transport -------------------------------------------------------------

    private def url(path : String, params : URI::Params?) : String
      query = params.try(&.to_s).presence
      query ? "#{Config.api_url(path)}?#{query}" : Config.api_url(path)
    end

    private def call(method : String, url : String, body : Bytes? = nil, type : String? = nil,
                     accept : String = "application/json", authenticate : Bool = true, attempt : Int32 = 0) : Http::Response
      headers = {"Authorization" => "Bearer #{token}", "Accept" => accept}
      headers["Content-Type"] = type if type
      response = begin
        Http.exec(method, url, headers, body)
      rescue ex : Einvoicing::ConnectorError
        # Coupure réseau : une lecture se rejoue ; une écriture a pu aboutir,
        # sa reprise passe par la vérification idempotente de l'appelant.
        raise ex unless method == "GET" && (delay = Config.retry_delays[attempt]?)
        sleep delay
        return call(method, url, body, type, accept, authenticate, attempt + 1)
      end
      if response.status == 401 && authenticate
        store.clear_access
        return call(method, url, body, type, accept, false, attempt)
      end
      if response.status.in?(429, 503) && (delay = Config.retry_delays[attempt]?)
        sleep delay
        return call(method, url, body, type, accept, authenticate, attempt + 1)
      end
      response
    end

    private def ensure_success!(response : Http::Response) : Http::Response
      return response if response.success?
      message, code = begin
        json = JSON.parse(response.text)
        {json["message"]?.try(&.as_s?) || "", json["code"]?.try(&.as_i64?)}
      rescue JSON::ParseException
        {response.text[0, 200], nil}
      end
      raise AuthorizationRequired.new("SUPER PDP refuse l'accès (401) : raccordez de nouveau la plateforme") if response.status == 401
      raise ApiError.new(response.status, message, code)
    end

    private def parse(response : Http::Response) : JSON::Any
      return JSON::Any.new(nil) if response.body.empty?
      response.json
    end
  end
end
