# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension SUPERPDP (ADR-005 D4) : raccordement à SUPER
# PDP en deux modes (identifiants d'une application de la société, ou
# autorisation par le compte SUPER PDP), état de la connexion (mode bac à
# sable ou production toujours affiché, entreprise, vérification, lignes
# d'annuaire, régime de TVA de l'e-reporting), déconnexion. Montée par
# `partiduo-ui-bulma` sous `/ext/SUPERPDP/` (ADR-003 D3). La distribution la
# requiert après l'interface et celle d'EINV :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-superpdp"
# require "partiduo-document/ui/bulma"
# require "partiduo-einvoicing/ui/bulma"
# require "partiduo-superpdp/ui/bulma"
# ```
#
# puis ajoute `Superpdp::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Superpdp::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle d'accès
# est fait par l'interface, avant le handler, à partir du manifeste.
require "../../src/partiduo-superpdp"

require "./presenters"
require "./handlers/**"

module Superpdp
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/superpdp/`) et libellés d'écran (`locales/`, clés
    # `superpdp_ui.*`).
    class App < Marten::App
      label "superpdp_ui"
    end

    INSTALLED_APPS = [Superpdp::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/SUPERPDP/`, nommées `superpdp:<nom>`.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Superpdp::Ui::IndexHandler, name: "index"
      path "/connect", Superpdp::Ui::CredentialsHandler, name: "connect"
      path "/authorize", Superpdp::Ui::AuthorizeHandler, name: "authorize"
      path "/oauth/callback", Superpdp::Ui::CallbackHandler, name: "callback"
      path "/check", Superpdp::Ui::CheckHandler, name: "check"
      path "/vat-regime", Superpdp::Ui::VatRegimeHandler, name: "vat_regime"
      path "/disconnect", Superpdp::Ui::DisconnectHandler, name: "disconnect"
    end
  end
end

PartiduoUi::Extensions.mount Superpdp::CODE, Superpdp::Ui::ROUTES, permission: Superpdp::Api::CONFIGURE
