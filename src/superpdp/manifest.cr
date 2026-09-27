# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension SUPERPDP (ADR-003 D2, ADR-004 D8) : l'adaptateur
# de la plateforme agréée SUPER PDP, rien d'autre.
#
# * Dépendance : `EINV` (`depends_on`), dont elle implémente le connecteur
#   `Einvoicing::Connector` ; EINV dépend lui-même de DOCUMENT.
# * Permission : `superpdp.connection.manage` (raccorder, vérifier,
#   déconnecter SUPER PDP, voir l'état de la connexion). Enregistrer le
#   raccordement passe par `Einvoicing::Api.configure`, qui exige en plus
#   `einvoicing.settings.manage` (DECISIONS D-SPDP-003).
# * Menu : « SUPER PDP » sous « Paramètres », à côté du raccordement d'EINV.
# * Aucun abonnement : émission, réception, statuts et e-reporting sont
#   conduits par EINV, qui appelle l'adaptateur.
Partiduo::Modules.register do
  code "SUPERPDP"
  name "superpdp.module.name"
  version "0.1.0"
  requires_core "~> 0.1"
  depends_on "EINV"

  permission "superpdp.connection.manage"

  menu "SUPERPDP", parent: "SETTINGS", order: 91, route: "superpdp:index", permission: "superpdp.connection.manage",
    label: "superpdp.menu.superpdp"

  ui "bulma", path: "ui/bulma"
end
