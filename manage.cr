# SPDX-License-Identifier: AGPL-3.0-or-later

# Ligne de commande Marten de l'extension, composée avec le cœur, DOCUMENT,
# EINV et l'interface comme dans une distribution :
# `crystal run manage.cr -- <commande>` (`genmigrations superpdp`, `migrate`…).
require "partiduo-ui-bulma/partiduo_ui"
require "./src/partiduo-superpdp"
require "partiduo-document/ui/bulma"
require "partiduo-einvoicing/ui/bulma"
require "./ui/bulma/bulma"
require "./config/settings/base"
require "./config/settings/**"
require "partiduo/cli"
require "partiduo-document/cli"
require "partiduo-einvoicing/cli"
require "./src/partiduo-superpdp/cli"

Marten.setup
Marten::CLI.run
