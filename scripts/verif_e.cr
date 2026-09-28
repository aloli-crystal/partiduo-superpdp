# SPDX-License-Identifier: AGPL-3.0-or-later

# Vérification de bout en bout du lot E (justificatifs, facturation
# électronique, factures non électroniques) sur une instance
# « Comptabilité + Facturation » provisionnée par `bin/partiduo-provision`
# avec DOCUMENT, EINV (et SUPERPDP), par l'interface servie sur un vrai port
# local (serveur de Marten démarré dans ce processus).
#
# Plateforme agréée, `--adapter` :
#
# * `superpdp` : SUPER PDP simulée (double des specs, même processus) ;
# * `afnor` : plateforme XP Z12-013 simulée d'EINV (accusés automatiques) ;
# * `sandbox` : le *vrai* bac à sable SUPER PDP, identifiants lus dans
#   `~/.config/partiduo/superpdp-sandbox.env` (jamais affichés).
#
# Parcours (simulé) : raccordement, facture validée → transmise → Déposée ;
# facture d'achat papier saisie à la main avec sa pièce jointe ; factures
# fournisseur reçues (doublon de la facture papier détecté, autre facture
# pré-comptabilisée) ; encaissement lettré → Encaissée (212) émis ; facture à
# un particulier → canal courriel, e-reporting B2C ; justificatif
# photographié → saisi → rattaché. `--keep` laisse le serveur ouvert pour
# un essai dans un navigateur.
#
# ```
# set -a; . ../partiduo-app/tmp/instances/je-spdp/je-spdp.env; set +a
# MARTEN_ENV=development PARTIDUO_MEDIA_ROOT=$TMPDIR/je-spdp-media \
#   crystal run scripts/verif_e.cr -- --adapter=superpdp --host=je-spdp.partiduo.localhost \
#   --email=admin@je-spdp.test --invitation='<lien>' --port=8120
# ```
ENV["MARTEN_ENV"] ||= "development"

require "option_parser"
require "partiduo-ui-bulma/partiduo_ui"
require "../src/partiduo-superpdp"
require "partiduo-document/ui/bulma"
require "partiduo-einvoicing/ui/bulma"
require "../ui/bulma/bulma"
require "../config/settings/base"
require "../config/settings/**"
require "./verif/browser"
require "./verif/platforms"

module VerifE
  alias Inv = Partiduo::Api::Invoicing
  alias Acc = Partiduo::Api::Accounting
  alias Cards = Partiduo::Api::Cards
  alias EApi = Einvoicing::Api
  alias DApi = Document::Api
  alias Spdp = Superpdp::SpecSupport::SimulatedSuperpdp

  SANDBOX_FILE = Path.home.join(".config", "partiduo", "superpdp-sandbox.env").to_s

  class Run
    include Verif::Steps

    @actor : Partiduo::Api::Actor? = nil
    @spdp : Spdp? = nil
    @afnor : Verif::AutoAckPlatform? = nil
    @sandbox : Hash(String, String)? = nil

    def initialize(@adapter : String, @host : String, @port : Int32, @email : String, @password : String,
                   @invitation : String?)
      @stamp = Time.local.to_s("%H%M%S")
    end

    def system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def actor : Partiduo::Api::Actor
      @actor ||= Partiduo::Api::Auth.actor(Partiduo::Api::Auth.login_password(Partiduo::Api::Actor.anonymous,
        Partiduo::Api::Auth::PasswordLoginInput.new(@email, @password)).value!.session_token!)
    end

    def d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def today : String
      Partiduo::Api::Core.today.to_s("%d/%m/%Y")
    end

    def run : Nil
      settings = Partiduo::Api::Core.settings(system)
      puts "== Instance #{@host} : « #{settings.company_name} », SIREN #{settings.siren}, modules actifs " \
           "#{Partiduo::Modules::State.active_codes.to_a.sort!.join(", ")} ; plateforme : #{@adapter} ; " \
           "serveur http://#{@host}:#{@port}/"
      platform!
      browser = Verif::Browser.new(@host, @port)
      login(browser)
      reference(browser)
      connect(browser)
      if @adapter == "sandbox"
        sandbox_journey(browser)
        return
      end
      invoice_id = sale(browser) || return
      paper_purchase(browser)
      incoming(browser)
      payment(browser, invoice_id)
      b2c(browser)
      receipt_photo(browser)
    end

    # --- Plateforme -------------------------------------------------------------

    @mail : Partiduo::Invoicing::Mail::MemoryTransport? = nil

    def platform! : Nil
      # Courriel : serveur SMTP simulé (messages gardés en mémoire) sauf si
      # l'instance en configure un (`PARTIDUO_SMTP_URL`).
      unless ENV["PARTIDUO_SMTP_URL"]?.presence
        memory = Partiduo::Invoicing::Mail::MemoryTransport.new
        @mail = memory
        Partiduo::Invoicing::Mail.transport = memory
      end
      case @adapter
      when "superpdp"
        platform = Spdp.new
        Superpdp::Config.retry_delays = [Time::Span.zero, Time::Span.zero]
        platform.add_company("Atelier Brunet SARL", Verif::COMPANY_SIREN, ["0225:#{Verif::COMPANY_SIREN}"], email: @email)
        platform.add_company("Atelier Morel SAS", Verif::CUSTOMER_SIREN, ["0225:#{Verif::CUSTOMER_SIREN}"])
        platform.add_company("Fournitures Martin SAS", Verif::SUPPLIER_SIREN, ["0225:#{Verif::SUPPLIER_SIREN}"])
        @spdp = platform
        Einvoicing::Http.transport = platform
      when "afnor"
        platform = Verif::AutoAckPlatform.new
        platform.page_size = 25
        @afnor = platform
        Einvoicing::Http.transport = platform
      when "sandbox"
        @sandbox = sandbox_credentials || raise "identifiants du bac à sable absents (#{SANDBOX_FILE})"
        Einvoicing::Http.transport = Superpdp::SpecSupport::ProxyTransport.from_env # nil : réseau direct
        Superpdp::Config.retry_delays = [1.seconds, 3.seconds]
      else
        raise "--adapter inconnu : #{@adapter}"
      end
    end

    def spdp : Spdp
      @spdp || raise "SUPER PDP simulée absente"
    end

    def spdp_company(siren : String) : Spdp::Company
      spdp.companies.find! { |item| item.number == siren }
    end

    # --- Connexion ----------------------------------------------------------------

    private def login(browser : Verif::Browser) : Nil
      section "Enrôlement et connexion"
      if invitation = @invitation
        path = "/invitation/#{invitation.split("/invitation/").last}"
        check("invitation acceptée") { redirect?(browser.submit(path, {} of String => String), "/account/enrollment") }
        check("mot de passe choisi à l'enrôlement") do
          browser.get("/account/enrollment")
          redirect?(browser.post("/account/enrollment", {"new_password" => @password, "confirmation" => @password}), "/login")
        end
      end
      check("connexion par mot de passe") { redirect?(browser.submit("/login", {"email" => @email, "password" => @password})) }
      check("tableau de bord : menus de DOCUMENT et d'EINV") do
        expect(browser.get("/"), 200, "/ext/DOCUMENT/", "/ext/EINV/")
      end
    end

    # --- Référentiel ----------------------------------------------------------------

    def customer_code : String
      "CLI-MOREL"
    end

    def private_code : String
      "CLI-JMARTIN"
    end

    def supplier_code : String
      "FOUR-MARTIN"
    end

    def item_code : String
      "CONSEIL"
    end

    private def card?(code : String) : Bool
      !Cards.card_by_code(system, code).nil?
    end

    private def reference(browser : Verif::Browser) : Nil
      section "Référentiel (fiches par l'interface)"
      customers = Cards.category_by_code(system, "CUSTOMER") || raise "catégorie CUSTOMER absente"
      suppliers = Cards.category_by_code(system, "SUPPLIER") || raise "catégorie SUPPLIER absente"
      items = Cards.category_by_code(system, "SALE") || raise "catégorie SALE absente"
      rate = Partiduo::Api::Vat.rate_by_code(system, "NOR") || raise "taux NOR absent"
      customer_siren = Verif::CUSTOMER_SIREN
      cards = [
        {customers.id, customer_code, {"name" => "Atelier Morel SAS", "siren" => customer_siren, "email" => "compta@morel.test"}},
        {customers.id, private_code, {"name" => "Jeanne Martin", "email" => "jeanne.martin@example.test"}},
        {suppliers.id, supplier_code, {"name" => "Fournitures Martin SAS", "siren" => Verif::SUPPLIER_SIREN}},
        {items.id, item_code, {"name" => "Conseil (heure)", "unit_code" => "HUR", "sale_price" => "80", "vat_rate_id" => rate.id.to_s}},
      ]
      cards.each do |(category, code, values)|
        next if card?(code)
        check("fiche #{code} créée (#{values["name"]})") do
          data = {"category_id" => category.to_s, "code" => code, "enabled" => "1"}.merge(values)
          if category != items.id
            data.merge!({"address.line1" => "3 rue du Port", "address.postcode" => "44100", "address.city" => "Nantes",
                         "address.country_code" => "FR"})
          end
          redirect?(browser.submit("/cards/new?category=#{category}", data, "/cards/new"), "/cards/")
        end
      end
      year = Partiduo::Api::Core.today.year
      unless Partiduo::Api::Core.fiscal_years(system).any?(&.year.==(year))
        check("exercice #{year} créé") do
          redirect?(browser.submit("/fiscal-years", {"year" => year.to_s, "start_year" => year.to_s, "start_month" => "1",
                                                     "months" => "12", "label" => ""}), "/fiscal-years")
        end
      end
      purchase_account
      if Inv.settings(system).sender_email.empty?
        check("paramètres de la Facturation : adresse d'expédition des courriels") do
          page = browser.get("/invoicing/settings")
          values = Verif.form_values(page.body).merge({"sender_email" => "facturation@brunet.test", "sender_name" => "Atelier Brunet"})
          redirect?(browser.post("/invoicing/settings", values), "/invoicing/settings")
        end
      end
    end

    # Compte de charge par défaut du journal d'achats (pré-comptabilisation).
    private def purchase_account : Nil
      ledger = Acc.ledgers(system, Acc::LedgerKind::Purchase).first
      return unless ledger.default_account.to_s.empty?
      check("journal d'achats #{ledger.code} : compte par défaut 6064") do
        begin
          Acc.account(system, "6064")
        rescue Partiduo::Api::NotFound
          Acc.create_account(system, Acc::AccountInput.new(number: "6064", label: "Fournitures administratives", parent: "60")).value!
        end
        input = Acc::LedgerInput.new(name: ledger.name, kind: ledger.kind, code: ledger.code, description: ledger.description,
          enabled: ledger.enabled, default_account: "6064", receipt_prefix: ledger.receipt_prefix,
          receipt_padding: ledger.receipt_padding, currency_code: ledger.currency_code.presence)
        Acc.update_ledger(system, ledger.id, input).success?
      end
    end

    # --- Raccordement ---------------------------------------------------------------

    private def connect(browser : Verif::Browser) : Nil
      section "Raccordement à la plateforme agréée (#{@adapter})"
      case @adapter
      when "superpdp"
        company = spdp_company(Verif::COMPANY_SIREN)
        check("SUPER PDP : identifiants de la société essayés et enregistrés (client credentials)") do
          redirect?(browser.submit("/ext/SUPERPDP/", {"client_id" => company.client_id, "client_secret" => company.client_secret},
            "/ext/SUPERPDP/connect"), "/ext/SUPERPDP/")
        end
        check("état de la connexion : bac à sable, lignes d'annuaire") do
          expect(browser.get("/ext/SUPERPDP/"), 200, "0225:#{Verif::COMPANY_SIREN}")
        end
      when "afnor"
        check("XP Z12-013 : raccordement enregistré (OAuth 2 client credentials)") do
          values = {"adapter" => "AFNOR", "flow_url" => "https://pa.test/afnor-flow", "directory_url" => "https://pa.test/afnor-directory",
                    "token_url" => "https://pa.test/oauth2/token", "client_id" => Einvoicing::SpecSupport::SimulatedPlatform::CLIENT_ID,
                    "client_secret" => Einvoicing::SpecSupport::SimulatedPlatform::CLIENT_SECRET, "organization_id" => "",
                    "environment" => "sandbox"}
          redirect?(browser.submit("/ext/EINV/settings", values), "/ext/EINV/settings")
        end
        check("raccordement essayé depuis l'écran") do
          response = browser.post("/ext/EINV/settings/check")
          next redirect?(response) unless response.status_code == 302
          expect(browser.follow(response), 200, "XP Z12-013")
        end
      when "sandbox"
        values = @sandbox || raise "identifiants absents"
        check("vrai bac à sable SUPER PDP : identifiants du vendeur fictif enregistrés (non affichés)") do
          response = browser.submit("/ext/SUPERPDP/", {"client_id"     => values["SUPERPDP_SANDBOX_SELLER_CLIENT_ID"],
                                                       "client_secret" => values["SUPERPDP_SANDBOX_SELLER_CLIENT_SECRET"]}, "/ext/SUPERPDP/connect")
          next redirect?(response, "/ext/SUPERPDP/") unless response.status_code == 302
          page = browser.follow(response)
          body = page.body
          next "secret affiché sur la page" if body.includes?(values["SUPERPDP_SANDBOX_SELLER_CLIENT_SECRET"])
          status = Superpdp::Api.status(actor)
          note "mode #{status.mode}, entreprise #{status.company_name} (#{status.company_number})"
          status.mode == "sandbox" || "mode #{status.mode}"
        end
      end
      check("EINV : raccordement actif affiché avec son mode") do
        connection = EApi.connection(actor) || next "aucun raccordement"
        next "inactif" unless connection.active
        expect(browser.get("/ext/EINV/settings"), 200, "Bac à sable")
      end
    end

    # --- Facture de vente B2B ------------------------------------------------------------

    private def create_invoice(browser : Verif::Browser, customer : String, quantity : String) : Int64?
      invoice_id = nil
      check("facture saisie en brouillon pour #{customer} (#{quantity} h de conseil)") do
        values = {"kind" => "invoice", "customer" => customer, "line-0-item" => item_code, "line-0-quantity" => quantity}
        response = browser.submit("/invoicing/documents/new?kind=invoice", values, "/invoicing/documents/new")
        next redirect?(response) unless response.status_code == 302
        invoice_id = response.headers["Location"].split('/').last.to_i64
        true
      end
      id = invoice_id || return
      check("facture validée : numéro attribué, PDF/A-3 Factur-X") do
        response = browser.post("/invoicing/documents/#{id}/issue")
        next redirect?(response) unless response.status_code == 302
        view = Inv.document(actor, id)
        number = view.number || next "sans numéro#{danger(browser.follow(response))}"
        note "#{number} du #{view.issue_date.try(&.to_s("%Y-%m-%d"))} : #{view.totals.total_gross} € TTC, canal #{view.issue_channel}#{view.b2c ? " (B2C)" : ""}"
        expect(browser.follow(response), 200, number)
      end
      id
    end

    private def synchronize(browser : Verif::Browser, back : String = "/ext/EINV/outgoing") : Bool | String
      response = browser.post("/ext/EINV/sync", {"next" => back})
      return redirect?(response) unless response.status_code == 302
      page = browser.follow(response)
      message = text_of(page).match(/Synchronisation[^<]*/).try(&.[0]) || ""
      note message.strip unless message.empty?
      warning = page.body.match(/is-warning[^>]*>(.*?)<\//m).try { |match| HTML.unescape(match[1].gsub(/<[^>]+>/, " ")).strip }
      note "avertissement : #{warning}" if warning && !warning.empty?
      page.status_code == 200 || "HTTP #{page.status_code}"
    end

    private def sale(browser : Verif::Browser) : Int64?
      section "Facture validée → transmise → Déposée"
      id = create_invoice(browser, customer_code, "10") || return
      check("canal proposé : plateforme (client professionnel français)") do
        view = Inv.document(actor, id)
        view.issue_channel == "platform" && !view.b2c || "#{view.issue_channel}, b2c #{view.b2c}"
      end
      check("facture relevée par EINV à l'émission (invoice.issued), à transmettre") do
        row = EApi.transmission_for_invoice(actor, id) || next "non relevée"
        row.route == "platform" && row.status == "pending" || "#{row.route} / #{row.status}"
      end
      check("synchronisation depuis l'écran : facture transmise") { synchronize(browser) }
      check("statut « Déposée » (200) sur la facture émise") do
        row = EApi.transmission_for_invoice(actor, id) || next "non relevée"
        note "transmission #{row.id} : #{row.status}, dernier code #{row.last_code}, référence #{row.platform_ref}, #{row.syntax} #{row.profile}"
        next "statut #{row.status} (#{row.last_code}) #{row.error}" unless row.status == "deposited"
        expect(browser.get("/ext/EINV/outgoing/#{row.id}"), 200, "Déposée", Inv.document(actor, id).number.to_s)
      end
      check("côté plateforme : PDF/A-3 Factur-X reçu, acheminé chez le client") do
        number = Inv.document(actor, id).number.to_s
        case @adapter
        when "superpdp"
          sent = spdp.invoices_of(spdp_company(Verif::COMPANY_SIREN), "out").find { |item| String.new(item.content).includes?(number) } ||
                 next "facture absente de SUPER PDP"
          arrived = spdp.invoices_of(spdp_company(Verif::CUSTOMER_SIREN), "in").any? { |item| item.twin_id == sent.id }
          next "non acheminée chez le client" unless arrived
          next "type #{sent.content_type}" unless sent.content_type == "application/pdf"
          codes = spdp.events_of(sent).map(&.status_code)
          note "SUPER PDP : facture #{sent.id}, #{sent.processing_rule}, statuts #{codes.join(", ")}"
          true
        else
          flow = @afnor.try(&.sent("CustomerInvoice").find { |item| String.new(item.content).includes?(number) }) || next "flux absent"
          note "XP Z12-013 : flux #{flow.id} #{flow.syntax} #{flow.profile} #{flow.rule}, accusé #{flow.ack}"
          flow.ack == "Ok" || "accusé #{flow.ack}"
        end
      end
      check("facture marquée envoyée par la transmission (canal figé)") do
        view = Inv.document(actor, id)
        !view.sent_at.nil? || "non marquée envoyée"
      end
      id
    end

    # --- Facture d'achat papier -------------------------------------------------------------

    PAPER_NUMBER = "FM-2026-0412"

    private def paper_purchase(browser : Verif::Browser) : Nil
      section "Facture d'achat papier saisie à la main avec sa pièce jointe"
      pdf = File.read(ENV["VERIF_PAPER_PDF"]? || File.join(__DIR__, "verif", "facture-papier.pdf")).to_slice
      ledger = Acc.ledgers(system, Acc::LedgerKind::Purchase).first
      values = {"ledger_id" => ledger.id.to_s, "date" => today, "receipt" => "", "label" => "Ramettes de papier",
                "third_party" => supplier_code, "due_date" => "", "invoice_number" => PAPER_NUMBER, "invoice_date" => "05/09/2026",
                "line-0-account" => "6064", "line-0-label" => "", "line-0-amount" => "250", "line-0-vat_rate" => "NOR"}
      check("écran « Facture reçue hors plateforme » : pièce déposée et affichée à côté") do
        browser.get("/accounting/entries/received-invoice")
        fragment = browser.post_multipart("/accounting/entries/received-invoice/upload", {} of String => String,
          {"attachment_file" => {"facture-martin-0412.pdf", "application/pdf", pdf}})
        fragment.body.includes?(%(name="attachment_id")) || "pièce refusée#{danger(fragment)}"
      end
      check("contrôle instantané : écriture de 300,00 équilibrée") do
        live = browser.post("/accounting/entries/received-invoice/check", values, ::HTTP::Headers{"HX-Request" => "true"})
        expect(live, 200, "300,00")
      end
      check("facture #{PAPER_NUMBER} enregistrée avec sa pièce jointe, « Reçue hors plateforme »") do
        browser.get("/accounting/entries/received-invoice")
        response = browser.post_multipart("/accounting/entries/received-invoice", values,
          {"attachment_file" => {"facture-martin-0412.pdf", "application/pdf", pdf}})
        next redirect?(response, "/accounting/entries/") unless response.status_code == 302
        entry_id = response.headers["Location"].split('/').last.to_i64
        invoice = Acc.received_invoice_for_entry(actor, entry_id) || next "facture reçue absente"
        next "origine #{invoice.origin}" unless invoice.off_platform?
        next "sans pièce jointe" unless Acc.entry(actor, entry_id).attachment_id == invoice.attachment_id && invoice.attachment_id
        note "écriture #{Acc.entry(actor, entry_id).receipt} (#{invoice.total_amount} €), pièce jointe #{invoice.attachment_id}"
        expect(browser.follow(response), 200, "Facture #{PAPER_NUMBER} enregistrée", "Reçue hors plateforme", "Ouvrir la pièce jointe")
      end
    end

    # --- Factures fournisseur reçues ------------------------------------------------------------

    OTHER_NUMBER = "FM-2026-0413"

    private def deliver(number : String, net : String, vat : String, gross : String) : Nil
      content = Verif.ubl_invoice(number, net, vat, gross)
      case @adapter
      when "superpdp"
        spdp.deliver(spdp_company(Verif::SUPPLIER_SIREN), spdp_company(Verif::COMPANY_SIREN), content)
      else
        @afnor.try(&.deliver(content, "#{number}.xml", "UBL"))
      end
    end

    private def reception(number : String) : EApi::ReceptionView?
      EApi.receptions(actor).find(&.number.==(number))
    end

    private def incoming(browser : Verif::Browser) : Nil
      section "Factures fournisseur reçues par la plateforme"
      deliver(PAPER_NUMBER, "250.00", "50.00", "300.00")
      deliver(OTHER_NUMBER, "120.00", "24.00", "144.00")
      check("synchronisation : deux factures reçues") { synchronize(browser, "/ext/EINV/incoming") }
      check("factures reçues, fiche fournisseur reconnue par SIREN, boîte « Justificatifs à traiter »") do
        missing = [PAPER_NUMBER, OTHER_NUMBER].reject { |number| reception(number) }
        next "non reçue(s) : #{missing.join(", ")}" unless missing.empty?
        views = [PAPER_NUMBER, OTHER_NUMBER].compact_map { |number| reception(number) }
        next "fournisseur non reconnu" unless views.all?(&.supplier_card_id)
        next "sans justificatif" unless views.all?(&.receipt_id)
        expect(browser.get("/ext/EINV/incoming"), 200, PAPER_NUMBER, OTHER_NUMBER)
      end
      check("doublon détecté : #{PAPER_NUMBER} déjà saisie à la main (même fournisseur, numéro, montant)") do
        view = reception(PAPER_NUMBER) || next "non reçue"
        duplicates = EApi.duplicates(actor, view.id)
        next "aucun doublon signalé" if duplicates.received_invoices.empty?
        note "doublon : facture reçue hors plateforme #{duplicates.received_invoices.first.number} (écriture #{duplicates.received_invoices.first.receipt})"
        expect(browser.get("/ext/EINV/incoming/#{view.id}"), 200, "Doublon")
      end
      check("pré-comptabilisation du doublon refusée") do
        view = reception(PAPER_NUMBER) || next "non reçue"
        response = browser.post("/ext/EINV/incoming/#{view.id}/post")
        next "acceptée" if EApi.reception(actor, view.id).status == "posted"
        response.status_code == 422 || "HTTP #{response.status_code}"
      end
      check("#{OTHER_NUMBER} pré-comptabilisée depuis l'écran (journal d'achats, fichier reçu en pièce jointe)") do
        view = reception(OTHER_NUMBER) || next "non reçue"
        page = browser.get("/ext/EINV/incoming/#{view.id}")
        next expect(page, 200) unless page.status_code == 200
        response = browser.post("/ext/EINV/incoming/#{view.id}/post")
        next redirect?(response) unless response.status_code == 302
        posted = EApi.reception(actor, view.id)
        next "statut #{posted.status}" unless posted.status == "posted"
        entry = Acc.entry(actor, posted.entry_id || next "sans écriture")
        invoice = Acc.received_invoice_for_entry(actor, entry.id) || next "facture reçue absente"
        receipt = DApi.receipt(actor, posted.receipt_id || next "sans justificatif")
        next "origine #{invoice.origin}" unless invoice.origin.platform?
        next "pièce jointe #{entry.attachment_id}" unless entry.attachment_id == receipt.original_attachment_id
        lines = entry.lines.map { |line| "#{line.account_number} #{line.side.debit? ? "D" : "C"} #{line.amount}" }
        note "écriture #{entry.ledger_code} #{entry.receipt} : #{lines.join(" ; ")}"
        entry.total_debit == d("144") || "total #{entry.total_debit}"
      end
    end

    # --- Encaissement et 212 ------------------------------------------------------------------

    private def payment(browser : Verif::Browser, id : Int64) : Nil
      section "Encaissement lettré → Encaissée (212)"
      number = Inv.document(actor, id).number.to_s
      gross = Inv.document(actor, id).totals.total_gross
      sale = Acc.entries(actor, Acc::EntryQuery.new(source: "invoice:#{id}")).first? || return check("écriture de vente") { "absente" }
      card = Cards.card_by_code(actor, customer_code) || raise "fiche absente"
      account = (Acc.card_account(actor, card.id) || raise "client sans compte").account.number
      customer_line = sale.lines.find! { |line| line.account_number == account }.id
      bank = Acc.ledger_by_code(actor, "F01")
      amount = gross.to_s.sub('.', ',')
      check("encaissement de #{gross} € saisi en banque (#{bank.code})") do
        browser.get("/accounting/entries/financial")
        redirect?(browser.post("/accounting/entries/financial", {"ledger_id" => bank.id.to_s, "date" => today,
                                                                 "line-0-account" => customer_code, "line-0-label" => "Virement #{number}",
                                                                 "line-0-debit" => amount}), "/accounting/entries/financial")
      end
      check("lettrage de la vente et de l'encaissement depuis l'écran de lettrage") do
        page = browser.get("/accounting/matching?#{URI::Params.encode({"q" => customer_code})}")
        ids = page.body.scan(/name="line" value="(\d+)"/).map(&.[1].to_i64)
        other = ids.find(&.!=(customer_line)) || next "ligne de l'encaissement absente"
        response = browser.post_pairs("/accounting/matching", [{"q", customer_code}, {"line", customer_line.to_s}, {"line", other.to_s}])
        redirect?(response)
      end
      check("facture payée (payment.matched)") do
        view = Inv.document(actor, id)
        view.effective_status == "paid" || view.effective_status
      end
      check("synchronisation : « Encaissée » (212) émis sur la facture déposée") { synchronize(browser) }
      check("statut 212 émis, avec son montant, lu par la plateforme") do
        row = EApi.transmission_for_invoice(actor, id) || next "non relevée"
        events = EApi.transmission_events(actor, row.id)
        paid = events.find { |event| event.code == "212" } || next "212 absent (#{events.map(&.code).join(", ")})"
        next "212 non envoyé (#{paid.state} #{paid.error})" unless paid.sent_at
        note "212 : #{paid.amount} €, état #{paid.state} ; transmission #{row.status}"
        platform = case @adapter
                   when "superpdp"
                     sent = spdp.invoices_of(spdp_company(Verif::COMPANY_SIREN), "out").find! { |item| String.new(item.content).includes?(number) }
                     spdp.events_of(sent).any? { |event| event.status_code == "fr:212" } || "fr:212 absent de SUPER PDP"
                   else
                     @afnor.try(&.sent("CustomerInvoiceLC").any? { |flow| String.new(flow.content).includes?(number) && String.new(flow.content).includes?("212") }) || "flux CDAR 212 absent"
                   end
        next platform unless platform == true
        expect(browser.get("/ext/EINV/outgoing/#{row.id}"), 200, "Encaissée")
      end
    end

    # --- Particulier : courriel et e-reporting B2C ---------------------------------------------

    # ameba:disable Metrics/CyclomaticComplexity
    private def b2c(browser : Verif::Browser) : Nil
      section "Facture à un particulier → canal courriel, e-reporting B2C"
      card = Cards.card_by_code(actor, private_code) || raise "fiche absente"
      check("canal proposé pour Jeanne Martin : courriel, B2C (particulier)") do
        proposal = Inv.propose_channel(actor, card.id)
        proposal.channel == "email" && proposal.b2c || "#{proposal.channel}, b2c #{proposal.b2c}"
      end
      id = create_invoice(browser, private_code, "2") || return
      check("facture au particulier : canal courriel, marquée B2C") do
        view = Inv.document(actor, id)
        view.issue_channel == "email" && view.b2c || "#{view.issue_channel}, b2c #{view.b2c}"
      end
      check("facture envoyée par courriel depuis l'écran") do
        page = browser.get("/invoicing/documents/#{id}/send")
        next expect(page, 200) unless page.status_code == 200
        response = browser.post("/invoicing/documents/#{id}/send", {"to" => card.email, "cc" => "", "subject" => "", "body" => ""})
        next redirect?(response) unless response.status_code == 302
        if memory = @mail
          message = memory.messages.last? || next "aucun courriel"
          next "destinataire #{message.to}" unless message.to == [card.email]
          note "courriel à #{message.to.join(", ")} : « #{message.subject} », pièces #{message.attachments.map(&.filename).join(", ")}"
        end
        expect(browser.follow(response), 200, card.email)
      end
      check("EINV : voie B2C (e-reporting), transmise à la synchronisation") do
        row = EApi.transmission_for_invoice(actor, id) || next "non relevée"
        next "voie #{row.route}" unless row.route == "b2c"
        result = synchronize(browser)
        next result unless result == true
        row = EApi.transmission(actor, row.id)
        note "transmission #{row.id} : voie #{row.route}, #{row.syntax}, statut #{row.status} (#{row.last_code})"
        row.status == "deposited" || "statut #{row.status} #{row.error}"
      end
      check("côté plateforme : transaction B2C déclarée (règle B2C, note BAR)") do
        number = Inv.document(actor, id).number.to_s
        case @adapter
        when "superpdp"
          sent = spdp.invoices_of(spdp_company(Verif::COMPANY_SIREN), "out").find { |item| String.new(item.content).includes?(number) } ||
                 next "absente de SUPER PDP"
          next "règle #{sent.processing_rule}" unless sent.processing_rule == "B2C"
          String.new(sent.content).includes?("BAR") || "note BAR absente"
        else
          flow = @afnor.try(&.sent.find { |item| String.new(item.content).includes?(number) }) || next "flux absent"
          note "flux #{flow.id} #{flow.syntax} règle #{flow.rule}"
          flow.rule == "B2C" || "règle #{flow.rule}"
        end
      end
      check("facture marquée envoyée (courriel), canal figé") do
        view = Inv.document(actor, id)
        view.sent_at && view.issue_channel == "email" || "#{view.issue_channel}, envoyée #{view.sent_at}"
      end
    end

    # --- Justificatif photographié --------------------------------------------------------------

    private def receipt_photo(browser : Verif::Browser) : Nil
      section "Justificatif photographié → saisi → rattaché"
      photo = File.read(ENV["VERIF_PHOTO"]? || File.join(__DIR__, "verif", "ticket.jpg")).to_slice
      receipt_id = nil
      check("page d'accueil : bouton « Photographier un justificatif » (capture caméra)") do
        expect(browser.get("/ext/DOCUMENT/"), 200, %(capture="environment"))
      end
      check("photo déposée avec montant et fournisseur, vignette produite") do
        browser.get("/ext/DOCUMENT/")
        response = browser.post_multipart("/ext/DOCUMENT/capture",
          {"supplier" => "#{supplier_code} · Fournitures Martin SAS", "amount" => "57,60", "date" => today, "kind" => "ticket",
           "reference" => "T-#{@stamp}", "note" => "Cartouches"}, {"file" => {"IMG_#{@stamp}.JPG", "image/jpeg", photo}})
        next redirect?(response, "/ext/DOCUMENT/") unless response.status_code == 302
        receipt = DApi.receipts(actor).find { |item| item.reference == "T-#{@stamp}" } || next "justificatif absent"
        receipt_id = receipt.id
        next "source #{receipt.source}" unless receipt.source == "photo"
        next "sans vignette" unless receipt.thumbnail_attachment_id && receipt.preview_attachment_id
        thumb = browser.get("/ext/DOCUMENT/#{receipt.id}/file/thumbnail")
        note "justificatif #{receipt.id} : #{receipt.content_type}, #{receipt.byte_size} octets, vignette #{thumb.body.bytesize} octets"
        thumb.status_code == 200 || "vignette HTTP #{thumb.status_code}"
      end
      id = receipt_id || return
      entry_id = nil
      check("« Saisir l'écriture » : image à côté, écriture d'achat enregistrée") do
        page = browser.get("/ext/DOCUMENT/#{id}/entry")
        next expect(page, 200) unless page.status_code == 200
        ledger = Acc.ledgers(system, Acc::LedgerKind::Purchase).first
        values = {"ledger_id" => ledger.id.to_s, "date" => today, "receipt" => "", "third_party" => supplier_code, "due_date" => "",
                  "label" => "Cartouches d'encre", "line-0-account" => "6064", "line-0-label" => "Cartouches",
                  "line-0-amount" => "48", "line-0-vat_rate" => "NOR", "invoice_number" => "T-#{@stamp}"}
        response = browser.post("/ext/DOCUMENT/#{id}/entry", values)
        next redirect?(response) unless response.status_code == 302
        receipt = DApi.receipt(actor, id)
        entry_id = receipt.entry_id
        next "statut #{receipt.status}" unless receipt.status == "attached"
        entry = Acc.entry(actor, receipt.entry_id || next "sans écriture")
        note "écriture #{entry.receipt} : #{entry.total_debit} €, pièce jointe #{entry.attachment_id}"
        entry.attachment_id == receipt.original_attachment_id || "photo non jointe à l'écriture"
      end
      check("justificatif « Rattaché » dans la boîte") do
        entry = Acc.entry(actor, entry_id || next "sans écriture")
        expect(browser.get("/ext/DOCUMENT/?status=attached"), 200, "Rattaché à #{entry.receipt}")
      end
    end

    # --- Vrai bac à sable SUPER PDP ----------------------------------------------------------------

    private def sandbox_credentials : Hash(String, String)?
      Verif::Sandbox.credentials
    end

    @buyer : Superpdp::Connector? = nil

    private def buyer : Superpdp::Connector
      @buyer ||= Verif::Sandbox.connector(@sandbox || raise("identifiants absents"), "BUYER")
    end

    @buyer_siren : String? = nil

    # Adresse de l'acheteur fictif dans l'annuaire (`SIREN_SUFFIXE`).
    private def sandbox_buyer_address : String
      @buyer_siren ||= Verif::Sandbox.address(buyer)
    end

    private def poll(what : String, timeout = 120.seconds, &) : Bool | String
      deadline = Time.instant + timeout
      loop do
        return true if yield
        return "délai dépassé : #{what}" if Time.instant > deadline
        sleep 3.seconds
      end
    end

    private def sandbox_journey(browser : Verif::Browser) : Nil
      section "Émission vers l'acheteur fictif du bac à sable"
      check("annuaire du bac à sable : adresse de l'acheteur fictif #{sandbox_buyer_address}") { !sandbox_buyer_address.empty? }
      # Les entreprises fictives du bac à sable ont des numéros hors clé de
      # Luhn (000000001) que la fiche refuse : le SIREN du client est posé
      # en base pour ce seul essai (DECISIONS D-VE-003).
      seller = Superpdp::Api.status(actor).company_number
      check("SIREN du dossier aligné sur le vendeur fictif du raccordement (#{seller})") do
        Marten::DB::Connection.default.open(&.exec("UPDATE core_settings SET siren = $1", seller))
        Partiduo::Api::Core.settings(system).siren == seller || "SIREN non posé"
      end
      check("fiche #{customer_code} adressée à l'acheteur fictif (0225:#{sandbox_buyer_address})") do
        siren, _, suffix = sandbox_buyer_address.partition('_')
        Marten::DB::Connection.default.open(&.exec("UPDATE cards_card SET siren = $1, routing_id = $2 WHERE code = $3",
          siren, suffix, customer_code))
        Cards.card_by_code(system, customer_code).try(&.siren) == siren || "SIREN non posé"
      end
      # Le bac à sable refuse un numéro déjà déposé par le même vendeur (autre
      # passage de cette vérification) : le compteur de l'instance neuve
      # repart d'un nombre tiré de l'heure (DECISIONS D-VE-003).
      check("compteur des factures avancé (numéro inédit dans le bac à sable)") do
        start = Time.utc.to_s("%j%H%M").to_i
        Marten::DB::Connection.default.open(&.exec("INSERT INTO invoicing_counter (series, year, last_number, last_date) " \
                                                   "VALUES ('F', $1, $2, $3) ON CONFLICT DO NOTHING", Partiduo::Api::Core.today.year, start,
          Partiduo::Api::Core.today))
        true
      end
      id = create_invoice(browser, customer_code, "1") || return
      check("facture transmise depuis l'écran, puis « Déposée » (200) relue par curseur") do
        row = EApi.transmission_for_invoice(actor, id) || next "non relevée"
        next "voie #{row.route}" unless row.route == "platform"
        poll("statut 200 de #{Inv.document(actor, id).number}") do
          synchronize(browser)
          current = EApi.transmission(actor, row.id)
          next false if current.status == "pending" && current.error.empty?
          raise "statut #{current.status} (#{current.last_code}) #{current.error}" if current.status.in?("rejected", "failed")
          current.status.in?("deposited", "approved", "paid")
        end
      end
      row = EApi.transmission_for_invoice(actor, id)
      row.try { |item| note "transmission #{item.id} : #{EApi.transmission(actor, item.id).status}, référence SUPER PDP #{item.platform_ref}" }

      section "Réception d'une facture de l'acheteur fictif (vrai bac à sable)"
      number = "PDUO-JE-#{Time.utc.to_s("%Y%m%d%H%M%S")}"
      check("l'acheteur fictif dépose une facture adressée au dossier") do
        seller_address = Superpdp::Api.directory_lines(actor).value!.find { |line| !line.reply_to }.try(&.identifier) || next "pas de ligne d'annuaire"
        content = Verif::Sandbox.invoice(buyer, seller_address.lchop("0225:"), number)
        submission = buyer.submit(Verif::Sandbox.outgoing(number, content))
        note "déposée par l'acheteur : #{submission.platform_ref} (#{submission.status})"
        submission.status != "error" || "refusée"
      end
      check("facture reçue par la synchronisation de l'écran, dans « Justificatifs à traiter »") do
        poll("réception de #{number}") do
          synchronize(browser, "/ext/EINV/incoming")
          !reception(number).nil?
        end
      end
      reception(number).try do |view|
        note "réception #{view.id} : #{view.supplier_name}, #{view.total_gross} €, statut #{view.status}, justificatif #{view.receipt_id}"
        check("facture reçue affichée à l'écran") { expect(browser.get("/ext/EINV/incoming/#{view.id}"), 200, number) }
      end
    end
  end
end

adapter = "superpdp"
host = "je-spdp.partiduo.localhost"
email = ""
password = ENV["PARTIDUO_DEMO_PASSWORD"]? || "Verif-lotE-Partiduo-2026"
invitation = nil
port = 8120
keep = false
serve_only = false
OptionParser.parse do |parser|
  parser.banner = "Usage : crystal run scripts/verif_e.cr -- --adapter=superpdp|afnor|sandbox --host=HÔTE --email=ADRESSE [--invitation=LIEN] [--port=N] [--keep]"
  parser.on("--adapter=NAME", "plateforme : superpdp, afnor, sandbox") { |value| adapter = value }
  parser.on("--host=HOST", "hôte de l'instance") { |value| host = value }
  parser.on("--email=EMAIL", "adresse de l'administrateur") { |value| email = value }
  parser.on("--password=PASSWORD", "mot de passe") { |value| password = value }
  parser.on("--invitation=LINK", "lien d'invitation (premier passage)") { |value| invitation = value }
  parser.on("--port=PORT", "port local du serveur") { |value| port = value.to_i }
  parser.on("--keep", "laisse le serveur ouvert après le parcours") { keep = true }
  parser.on("--serve-only", "sert l'instance sans rejouer le parcours (essai dans un navigateur)") { serve_only = true }
end
if adapter == "probe"
  # Entreprises fictives du vrai bac à sable (sans aucun secret) : de quoi
  # provisionner l'instance au SIREN du vendeur.
  values = Verif::Sandbox.credentials || abort "identifiants du bac à sable absents"
  Einvoicing::Http.transport = Superpdp::SpecSupport::ProxyTransport.from_env
  if id = ENV["VERIF_INVOICE"]?
    json = Verif::Sandbox.connector(values, "SELLER").client.get_json("/invoices/#{id}")
    json.as_h.each { |key, value| puts "#{key} : #{value.to_json[0, 300]}" unless key.in?("content", "file") }
    exit
  end
  if ENV["VERIF_TEST_INVOICE"]?
    xml, _ = Verif::Sandbox.connector(values, "SELLER").client.get_bytes("/invoices/generate_test_invoice", URI::Params{"format" => "cii"}, "application/xml")
    text = String.new(xml)
    File.write(ENV["VERIF_TEST_INVOICE"], text)
    exit
  end
  if id = ENV["VERIF_VALIDATE"]?
    # Rapport du validateur SUPER PDP sur le PDF/A-3 Factur-X d'une facture
    # de l'instance (`DATABASE_URL`).
    Marten.setup
    pdf = Partiduo::Api::Invoicing.document_pdf(Partiduo::Api::Actor.system, id.to_i64)
    report = Verif::Sandbox.connector(values, "SELLER").validate(pdf.filename, pdf.content, "application/pdf")
    puts "is_valid : #{report["is_valid"]?}"
    (report["subreports"]?.try(&.as_a?) || [] of JSON::Any).each do |sub|
      %w[failures messages].each do |kind|
        (sub[kind]?.try(&.as_a?) || [] of JSON::Any).each do |item|
          puts "#{kind} #{item["rule"]?} : #{item["message"]?.to_s.lines.first?.to_s.strip}"
        end
      end
    end
    exit
  end
  %w[SELLER BUYER].each do |role|
    company = Verif::Sandbox.connector(values, role).company
    puts "#{role} : #{company["formal_name"]?} ; #{company["number_scheme"]?} #{company["number"]?} ; env #{company["env"]?} ; " \
         "#{company["address"]?}, #{company["postcode"]?} #{company["city"]?}"
  end
  exit
end
abort "--email est obligatoire" if email.empty?

Marten.configure(&.log_level=(::Log::Severity::Warn))
Marten.setup
Verif.serve(port)
run = VerifE::Run.new(adapter, host, port, email, password, invitation)
if serve_only
  # Plateforme simulée neuve : raccorder de nouveau depuis l'écran.
  run.platform!
  puts "== Serveur ouvert : http://#{host}:#{port}/ (plateforme #{adapter} ; Ctrl-C pour arrêter)"
  sleep
end
run.run
puts run.failures.zero? ? "== Tout est vert (#{run.steps} étapes)." : "== #{run.failures} étape(s) en échec sur #{run.steps} : #{run.failed.join(" ; ")}"
if keep
  puts "== Serveur ouvert : http://#{host}:#{port}/ (Ctrl-C pour arrêter)"
  sleep
end
exit(run.failures.zero? ? 0 : 1)
