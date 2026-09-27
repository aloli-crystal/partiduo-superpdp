# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  module SpecSupport
    alias E = Einvoicing::SpecSupport
    alias Api = Superpdp::Api

    SYSTEM = Partiduo::Api::Actor.system

    @@platform : SimulatedSuperpdp?

    def self.platform : SimulatedSuperpdp
      @@platform || raise "SUPER PDP simulée absente"
    end

    def self.reset_platform : SimulatedSuperpdp
      platform = SimulatedSuperpdp.new
      @@platform = platform
      Einvoicing::Http.transport = platform
      platform
    end

    # Entreprises de la plateforme simulée : le dossier (Atelier Brunet,
    # SIREN du dossier de test), son client (Atelier Morel) et son
    # fournisseur (Fournitures Martin), mêmes SIREN que les specs d'EINV.
    def self.company : SimulatedSuperpdp::Company
      platform.companies.find { |item| item.number == E::COMPANY_SIREN } ||
        platform.add_company("Atelier Brunet SARL", E::COMPANY_SIREN,
          ["0225:#{E::COMPANY_SIREN}", "0225:#{E::COMPANY_SIREN}_replyto"], email: "admin@brunet.test")
    end

    def self.customer_company : SimulatedSuperpdp::Company
      platform.companies.find { |item| item.number == E::CUSTOMER_SIREN } ||
        platform.add_company("Atelier Morel SAS", E::CUSTOMER_SIREN, ["0225:#{E::CUSTOMER_SIREN}"])
    end

    def self.supplier_company : SimulatedSuperpdp::Company
      platform.companies.find { |item| item.number == E::SUPPLIER_SIREN } ||
        platform.add_company("Fournitures Martin SAS", E::SUPPLIER_SIREN, ["0225:#{E::SUPPLIER_SIREN}"])
    end

    # Administrateur du dossier : permissions d'EINV et de SUPERPDP.
    def self.admin : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(E.admin.user_id || 1_i64, E::PERMISSIONS + [Api::CONFIGURE], level: 3)
    end

    # Dossier d'EINV (régime `fr` ou `be`) avec SUPERPDP actif.
    def self.books(regime : String = "fr") : Nil
      E.books(regime)
      Partiduo::Api::Modules.activate(SYSTEM, "SUPERPDP").value!
      nil
    end

    # Raccordement en mode client credentials avec les identifiants de
    # l'entreprise du dossier.
    def self.connect(company : SimulatedSuperpdp::Company = self.company) : Api::StatusView
      Api.connect_credentials(admin, Api::CredentialsInput.new(company.client_id, company.client_secret)).value!
    end

    # Connecteur du raccordement actif.
    def self.connector : Superpdp::Connector
      Einvoicing::Connections.connector.as(Superpdp::Connector)
    end

    def self.with_operator(&)
      previous = {ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_ID"]?, ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_SECRET"]?}
      ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_ID"] = SimulatedSuperpdp::OPERATOR_CLIENT_ID
      ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_SECRET"] = SimulatedSuperpdp::OPERATOR_CLIENT_SECRET
      yield
    ensure
      if previous
        previous[0].nil? ? ENV.delete("PARTIDUO_SUPERPDP_OAUTH_CLIENT_ID") : (ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_ID"] = previous[0].to_s)
        previous[1].nil? ? ENV.delete("PARTIDUO_SUPERPDP_OAUTH_CLIENT_SECRET") : (ENV["PARTIDUO_SUPERPDP_OAUTH_CLIENT_SECRET"] = previous[1].to_s)
      end
    end

    # Raccordement en mode authorization code : lancement, consentement
    # sur la plateforme simulée, retour.
    def self.authorize(company : SimulatedSuperpdp::Company = self.company) : Api::StatusView
      start = Api.start_authorization(admin, Api::AuthorizationInput.new(redirect_uri: SimulatedSuperpdp::REDIRECT_URI,
        login_hint: company.email, company_number: company.number, company_number_scheme: "fr_siren")).value!
      code, state = platform.consent(start.url, company)
      Api.complete_authorization(admin, Api::CallbackInput.new(state: state, code: code)).value!
    end
  end
end

# Chaque exemple part d'une SUPER PDP simulée vierge, sans attente entre
# deux tentatives, sans application OAuth d'opérateur.
Spec.before_each do
  Superpdp::SpecSupport.reset_platform
  Superpdp::Config.retry_delays = [Time::Span.zero, Time::Span.zero]
  ENV.delete("PARTIDUO_SUPERPDP_OAUTH_CLIENT_ID")
  ENV.delete("PARTIDUO_SUPERPDP_OAUTH_CLIENT_SECRET")
  ENV.delete("PARTIDUO_SUPERPDP_REDIRECT_URI")
end
