# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "digest/sha256"
require "openssl"
require "uri"

module Superpdp
  # OAuth 2.1, mode _authorization code_ (ADR-004 D8) : `state` anti-CSRF,
  # PKCE (RFC 7636, méthode `S256`), adresse d'autorisation SUPER PDP avec
  # les champs pré-remplis du parcours d'inscription.
  module OAuth
    # Schémas du numéro d'entreprise admis par
    # `superpdp_company_number_scheme`.
    SCHEMES = %w[fr_siren be_numero_entreprise sandbox]

    # Durée de validité d'une demande d'autorisation.
    LIFETIME = 10.minutes

    record Pkce, verifier : String, challenge : String

    # Vérificateur de 43 caractères (32 octets aléatoires) et son défi
    # `BASE64URL(SHA256(verifier))`.
    def self.pkce : Pkce
      verifier = Base64.urlsafe_encode(Random::Secure.random_bytes(32), padding: false)
      Pkce.new(verifier, challenge(verifier))
    end

    def self.challenge(verifier : String) : String
      Base64.urlsafe_encode(OpenSSL::Digest.new("SHA256").update(verifier).final, padding: false)
    end

    def self.state : String
      Base64.urlsafe_encode(Random::Secure.random_bytes(24), padding: false)
    end

    def self.digest(state : String) : String
      Digest::SHA256.hexdigest(state)
    end

    # Adresse du parcours d'autorisation SUPER PDP (vérification d'identité
    # et d'entreprise), pré-rempli : `login_hint` (courriel), numéro
    # d'entreprise et son schéma (indissociables).
    def self.authorize_url(client_id : String, redirect_uri : String, state : String, challenge : String,
                           login_hint : String = "", number : String = "", scheme : String = "") : String
      params = URI::Params.new
      params["response_type"] = "code"
      params["client_id"] = client_id
      params["redirect_uri"] = redirect_uri
      params["state"] = state
      params["code_challenge"] = challenge
      params["code_challenge_method"] = "S256"
      params["login_hint"] = login_hint unless login_hint.empty?
      unless number.empty? || scheme.empty?
        params["superpdp_company_number"] = number
        params["superpdp_company_number_scheme"] = scheme
      end
      "#{Config::AUTHORIZE_URL}?#{params}"
    end
  end
end
