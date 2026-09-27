# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  # Réponse d'erreur de l'API SUPER PDP (page « Erreurs » de la
  # documentation) : code HTTP, code d'erreur facultatif (`code`) et
  # message lisible (`message`, sans garantie de stabilité : jamais
  # interprété, seulement montré). Les 4xx signalent une requête refusée,
  # les 5xx une panne de la plateforme.
  class ApiError < Einvoicing::ConnectorError
    getter code : Int64?
    getter api_message : String

    def initialize(status : Int32, @api_message : String = "", @code : Int64? = nil)
      detail = @api_message.empty? ? "" : " : #{@api_message}"
      super("SUPER PDP #{status}#{detail}", status)
    end

    # Erreur de la plateforme : l'opération a pu aboutir ou non.
    def server? : Bool
      (status || 0) >= 500
    end
  end

  # Autorisation perdue : jeton de rafraîchissement refusé ou révoqué,
  # identifiants invalides. La société doit se raccorder de nouveau.
  class AuthorizationRequired < Einvoicing::ConnectorError
  end

  # Jeton de rafraîchissement refusé par SUPER PDP (`invalid_grant`) : il
  # est oublié.
  class RefreshRefused < AuthorizationRequired
  end

  # Entreprise pas (encore) vérifiée par SUPER PDP (KYB) : l'API répond
  # 403 tant que `company_verification_status` n'est pas `verified`.
  class NotVerified < Einvoicing::ConnectorError
    getter verification : String

    def initialize(@verification : String)
      super("entreprise non vérifiée par SUPER PDP (#{@verification})", 403)
    end
  end
end
