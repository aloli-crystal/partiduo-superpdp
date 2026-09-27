# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Configuration de l'instance (variables d'environnement, DECISIONS
  # D-005 du cœur) :
  #
  # * `PARTIDUO_SUPERPDP_OAUTH_CLIENT_ID` et
  #   `PARTIDUO_SUPERPDP_OAUTH_CLIENT_SECRET` : l'application OAuth que
  #   l'*opérateur* de Partiduo a déclarée chez SUPER PDP, pour le mode
  #   _authorization code_ (ADR-004 D8). Sans elles, seul le mode _client
  #   credentials_ est proposé.
  # * `PARTIDUO_SUPERPDP_REDIRECT_URI` : adresse de retour enregistrée dans
  #   cette application, si elle diffère de celle de l'instance
  #   (`https://<instance>/ext/SUPERPDP/oauth/callback`).
  #
  # L'adresse de l'API est fixe : bac à sable et production partagent la
  # même, le mode est porté par les identifiants.
  module Config
    BASE_URL      = "https://api.superpdp.tech"
    API_PREFIX    = "/v1.beta"
    TOKEN_PATH    = "/oauth2/token"
    AUTHORIZE_URL = "#{BASE_URL}/oauth2/authorize"
    REVOKE_PATH   = "/oauth2/revoke"

    def self.api_url(path : String) : String
      "#{BASE_URL}#{API_PREFIX}#{path}"
    end

    def self.oauth_url(path : String) : String
      "#{BASE_URL}#{path}"
    end

    def self.operator_client_id : String
      ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_ID"]?.to_s.strip
    end

    def self.operator_client_secret : String
      ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_SECRET"]?.to_s.strip
    end

    # Le mode _authorization code_ est-il proposé sur cette instance ?
    def self.authorization_code? : Bool
      !operator_client_id.empty? && !operator_client_secret.empty?
    end

    def self.redirect_uri_override : String?
      ENV["PARTIDUO_SUPERPDP_REDIRECT_URI"]?.presence
    end

    # Délais entre deux tentatives quand l'API répond « trop de requêtes »
    # ou « indisponible » (429, 503) : la requête n'a pas été traitée, on
    # peut la rejouer. Réglable pour les specs (aucune attente).
    class_property retry_delays : Array(Time::Span) = [1.seconds, 3.seconds]
  end
end
