# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-superpdp` : le métier de l'extension
# SUPERPDP (manifeste, connecteur SUPER PDP, raccordement OAuth 2.1,
# contrat `Superpdp::Api`), sans interface. L'interface Bulma est dans
# `ui/bulma/`, requise à part par la distribution :
# `require "partiduo-superpdp/ui/bulma"`.
#
# La distribution ajoute ensuite `Superpdp::INSTALLED_APPS` à ses
# applications Marten (après celles de `partiduo-einvoicing`), et
# `require "partiduo-superpdp/cli"` à sa ligne de commande (migrations).
require "partiduo"
require "partiduo-document"
require "partiduo-einvoicing"

require "./superpdp/app"
