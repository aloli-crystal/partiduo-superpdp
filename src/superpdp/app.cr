# SPDX-License-Identifier: AGPL-3.0-or-later

require "./manifest"
require "./config"
require "./errors"
require "./models/**"
require "./client"
require "./oauth"
require "./mapping"
require "./connector"
require "./services/**"
require "./api/**"

# Extension SUPERPDP de Partiduo : l'adaptateur de la plateforme agréée
# SUPER PDP pour l'extension EINV (ADR-004 D8). Même plan qu'une application
# du cœur (DECISIONS C1) : `manifest.cr`, `models/`, `migrations/`,
# `services/` (interne), `api/` (contrat public `Superpdp::Api`),
# `locales/` ; en plus `client.cr` (échanges authentifiés avec l'API JSON),
# `oauth.cr` (OAuth 2.1 : jetons, PKCE, révocation), `mapping.cr`
# (correspondances entre l'API SUPER PDP et `Einvoicing::Connector`) et
# `connector.cr` (l'adaptateur lui-même).
module Superpdp
  VERSION = "0.1.0"

  # Code du registre (ADR-003 D2) : `superpdp` dans `PARTIDUO_MODULES`.
  CODE = "SUPERPDP"

  # Code de l'adaptateur enregistré auprès d'EINV
  # (`Einvoicing::Connections.register`).
  ADAPTER = "SUPERPDP"

  # Application Marten du métier : modèles (tables `superpdp_*`),
  # migrations et libellés.
  class App < Marten::App
    label "superpdp"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Einvoicing::INSTALLED_APPS`.
  INSTALLED_APPS = [Superpdp::App] of Marten::Apps::Config.class
end

Einvoicing::Connections.register(Superpdp::Connector.adapter)
