# SPDX-License-Identifier: AGPL-3.0-or-later

module Superpdp
  module Ui
    # Base des écrans de l'extension. L'accès a déjà été contrôlé par
    # `PartiduoUi::ExtensionHandler` à partir du manifeste ; `Superpdp::Api`
    # le vérifie encore.
    abstract class Handler < PartiduoUi::ScreenHandler
      alias Api = Superpdp::Api

      def messages(result) : Array(String)
        result.errors.map { |error| fmt.message(error) }
      end

      def back : Marten::HTTP::Response
        go(Ui.url("index"))
      end

      # Adresse de retour du parcours d'autorisation sur cette instance
      # (sauf `PARTIDUO_SUPERPDP_REDIRECT_URI`, appliquée par le contrat).
      def redirect_uri : String
        scheme = request.secure? || Marten.env.production? ? "https" : "http"
        port = request.port
        default = (scheme == "https" && port == "443") || (scheme == "http" && port == "80")
        host = port.nil? || port.empty? || default ? request.host : "#{request.host}:#{port}"
        "#{scheme}://#{host}#{Ui.url("callback")}"
      end
    end

    # `/ext/SUPERPDP/` : état du raccordement et raccordement.
    class IndexHandler < Handler
      def get
        show(nil, {} of String => Array(String))
      end

      def show(form : String?, errors : Hash(String, Array(String)), values = {} of String => String,
               status : Int32 = 200) : Marten::HTTP::Response
        actor = current.actor
        view = Api.status(actor)
        lines = nil
        lines_error = nil
        if view.connected
          result = Api.directory_lines(actor)
          if result.success?
            lines = result.value!.map { |line| Present.line(line) }
          else
            lines_error = messages(result).join(" ")
          end
        end
        defaults = Api.authorization_defaults(actor, redirect_uri, current.session.try(&.email) || "")
        page("superpdp/index.html", {
          "title"         => I18n.t("superpdp_ui.title"),
          "crumbs"        => [crumb("core.menu.settings"), PartiduoUi::Screen::Crumb.new(I18n.t("superpdp_ui.title"))],
          "status"        => Present.status(view, fmt),
          "lines"         => lines.try { |items| listed(items) },
          "lines_error"   => lines_error,
          "vat_regimes"   => Api::VAT_REGIMES.map { |code| Ui.row({"value" => code, "label" => I18n.t("superpdp.vat_regimes.#{code}"), "selected" => code == view.vat_regime ? "1" : nil}) },
          "schemes"       => Api::SCHEMES.map { |code| Ui.row({"value" => code, "label" => I18n.t("superpdp.schemes.#{code}"), "selected" => code == (form == "authorize" ? values["company_number_scheme"]? : defaults.company_number_scheme) ? "1" : nil}) },
          "client_id"     => form == "connect" ? values["client_id"]? : view.client_id,
          "login_hint"    => form == "authorize" ? values["login_hint"]? : defaults.login_hint,
          "number"        => form == "authorize" ? values["company_number"]? : defaults.company_number,
          "authorization" => view.authorization_available ? "1" : nil,
          "form"          => form,
          "errors"        => Ui.row(errors.transform_values { |list| list.join(" ").as(String?) }),
          "base"          => errors["base"]?.try(&.join(" ")),
        }, status: status)
      end
    end

    # Mode _client credentials_ : identifiants d'une application SUPER PDP
    # de la société.
    class CredentialsHandler < IndexHandler
      def get
        back
      end

      def post
        values = {"client_id" => field("client_id"), "client_secret" => field("client_secret")}
        result = Api.connect_credentials(current.actor, Api::CredentialsInput.new(values["client_id"], values["client_secret"]))
        if result.success?
          flash["success"] = I18n.t("superpdp_ui.flash.connected", mode: I18n.t(result.value!.mode_key))
          return back
        end
        show("connect", errors_of(result), values.merge({"client_secret" => ""}), 422)
      end
    end

    # Mode _authorization code_ : redirection vers le parcours SUPER PDP.
    class AuthorizeHandler < IndexHandler
      def get
        back
      end

      def post
        values = {"login_hint" => field("login_hint"), "company_number" => field("company_number"),
                  "company_number_scheme" => field("company_number_scheme")}
        input = Api::AuthorizationInput.new(redirect_uri: redirect_uri, login_hint: values["login_hint"],
          company_number: values["company_number"], company_number_scheme: values["company_number_scheme"])
        result = Api.start_authorization(current.actor, input)
        return go(result.value!.url) if result.success?
        show("authorize", errors_of(result), values, 422)
      end
    end

    # Route de rappel du parcours d'autorisation (`state`, `code` ou
    # `error`).
    class CallbackHandler < Handler
      def get
        input = Api::CallbackInput.new(state: query("state"), code: query("code"), error: query("error"),
          error_description: query("error_description"))
        result = Api.complete_authorization(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("superpdp_ui.flash.connected", mode: I18n.t(result.value!.mode_key))
        else
          flash["danger"] = messages(result).join(" ")
        end
        back
      end
    end

    # Vérification du raccordement auprès de SUPER PDP.
    class CheckHandler < Handler
      def get
        back
      end

      def post
        result = Api.check(current.actor)
        if result.success?
          flash["success"] = I18n.t("superpdp_ui.flash.checked", mode: I18n.t(result.value!.mode_key))
        else
          flash["danger"] = messages(result).join(" ")
        end
        back
      end
    end

    # Régime de TVA de l'entreprise chez SUPER PDP (calendrier de
    # l'e-reporting).
    class VatRegimeHandler < Handler
      def get
        back
      end

      def post
        input = Api::VatRegimeInput.new(field("vat_regime"), field("has_vat_on_debits") == "1")
        result = Api.update_vat_regime(current.actor, input)
        if result.success?
          flash["success"] = I18n.t("superpdp_ui.flash.vat_regime")
        else
          flash["danger"] = messages(result).join(" ")
        end
        back
      end
    end

    # Déconnexion : jetons révoqués, plateforme débranchée.
    class DisconnectHandler < Handler
      def get
        back
      end

      def post
        Api.disconnect(current.actor)
        flash["success"] = I18n.t("superpdp_ui.flash.disconnected")
        back
      end
    end
  end
end
