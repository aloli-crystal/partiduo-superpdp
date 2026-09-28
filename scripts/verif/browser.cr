# SPDX-License-Identifier: AGPL-3.0-or-later

require "http/client"
require "http/formdata"

# Outils communs des vérifications de bout en bout du lot E
# (`scripts/verif_e.cr`) : navigateur HTTP vers un vrai serveur démarré dans
# le même processus, étapes notées.
module Verif
  # Navigateur : cookies, en-tête Host de l'instance, jeton CSRF repris de la
  # dernière page HTML lue, formulaires simples et `multipart/form-data`.
  class Browser
    getter jar = ::HTTP::Cookies.new
    @csrf : String? = nil

    def initialize(@host : String, @port : Int32, @locale : String = "fr")
    end

    def get(path : String) : ::HTTP::Client::Response
      perform("GET", path)
    end

    def submit(form_path : String, data : Hash(String, String), action : String = form_path) : ::HTTP::Client::Response
      get(form_path)
      post(action, data)
    end

    def post(path : String, data : Hash(String, String) = {} of String => String,
             headers : ::HTTP::Headers? = nil) : ::HTTP::Client::Response
      post_pairs(path, data.to_a, headers)
    end

    def post_pairs(path : String, pairs : Array({String, String}), headers : ::HTTP::Headers? = nil) : ::HTTP::Client::Response
      params = URI::Params.new
      pairs.each { |(name, value)| params.add(name, value) }
      params.add("csrftoken", @csrf.to_s)
      perform("POST", path, params.to_s, "application/x-www-form-urlencoded", headers)
    end

    # Formulaire avec fichiers : `files` associe le nom du champ à
    # {nom du fichier, type, contenu}.
    def post_multipart(path : String, fields : Hash(String, String),
                       files = {} of String => {String, String, Bytes}) : ::HTTP::Client::Response
      io = IO::Memory.new
      builder = ::HTTP::FormData::Builder.new(io, "partiduo-verif-#{Random::Secure.hex(6)}")
      fields.each { |name, value| builder.field(name, value) }
      builder.field("csrftoken", @csrf.to_s)
      files.each do |name, (filename, type, content)|
        builder.file(name, IO::Memory.new(content), ::HTTP::FormData::FileMetadata.new(filename: filename),
          ::HTTP::Headers{"Content-Type" => type})
      end
      builder.finish
      perform("POST", path, io.to_s, builder.content_type)
    end

    def follow(response : ::HTTP::Client::Response) : ::HTTP::Client::Response
      get(response.headers["Location"])
    end

    private def perform(method : String, path : String, body : String? = nil, content_type : String? = nil,
                        extra : ::HTTP::Headers? = nil) : ::HTTP::Client::Response
      headers = ::HTTP::Headers{"Host" => "#{@host}:#{@port}", "Accept-Language" => @locale, "User-Agent" => "partiduo-verif"}
      headers["Content-Type"] = content_type if content_type
      headers["Referer"] = "http://#{@host}:#{@port}#{path}"
      extra.try &.each { |name, values| headers[name] = values }
      request = ::HTTP::Request.new(method, path, headers, body)
      @jar.add_request_headers(request.headers)
      result = ::HTTP::Client.new("127.0.0.1", @port) do |client|
        client.read_timeout = 120.seconds
        client.exec(request)
      end
      result.cookies.each do |cookie|
        cookie.expired? || cookie.value.empty? ? @jar.delete(cookie.name) : (@jar << cookie)
      end
      if result.content_type.to_s.includes?("html") && (token = result.body.match(/name="csrftoken" value="([^"]+)"/).try(&.[1]))
        @csrf = token
      end
      result
    end
  end

  # Valeurs actuelles des champs d'un formulaire HTML (champs, cases
  # cochées, listes, zones de texte), comme un navigateur les enverrait.
  def self.form_values(html : String) : Hash(String, String)
    values = {} of String => String
    html.scan(/<input\b[^>]*>/m) do |match|
      tag = match[0]
      name = tag.match(/\bname="([^"]+)"/).try(&.[1]) || next
      next if name == "csrftoken"
      type = tag.match(/\btype="([^"]+)"/).try(&.[1]) || "text"
      next if type.in?("submit", "button", "file")
      next if type.in?("checkbox", "radio") && !tag.includes?(" checked")
      values[name] = HTML.unescape(tag.match(/\bvalue="([^"]*)"/).try(&.[1]) || (type == "checkbox" ? "1" : ""))
    end
    html.scan(/<textarea\b[^>]*name="([^"]+)"[^>]*>(.*?)<\/textarea>/m) { |match| values[match[1]] = HTML.unescape(match[2]) }
    html.scan(/<select\b[^>]*name="([^"]+)"[^>]*>(.*?)<\/select>/m) do |match|
      selected = match[2].match(/<option[^>]*value="([^"]*)"[^>]*\bselected/).try(&.[1]) ||
                 match[2].match(/<option[^>]*value="([^"]*)"/).try(&.[1]) || ""
      values[match[1]] = HTML.unescape(selected)
    end
    values
  end

  # Étapes notées : « ok » ou « ÉCHEC » avec la raison.
  module Steps
    getter failures = 0
    getter steps = 0
    getter failed = [] of String

    def section(title : String) : Nil
      puts "-- #{title}"
    end

    def check(label : String, & : -> Bool | String) : Nil
      @steps += 1
      outcome = begin
        yield
      rescue ex
        "#{ex.class}: #{ex.message}"
      end
      if outcome == true
        puts "  ok      #{label}"
      else
        @failures += 1
        @failed << label
        puts "  ÉCHEC   #{label}#{outcome.is_a?(String) ? " — #{outcome}" : ""}"
      end
    end

    def note(text : String) : Nil
      puts "          #{text}"
    end

    def text_of(response : ::HTTP::Client::Response) : String
      HTML.unescape(response.body).gsub(/[\x{00A0}\x{202F}]/, " ")
    end

    def expect(response : ::HTTP::Client::Response, status : Int32, *texts) : Bool | String
      return "HTTP #{response.status_code} au lieu de #{status}#{danger(response)}" unless response.status_code == status
      body = text_of(response)
      missing = texts.reject { |text| body.includes?(text) }
      return true if missing.empty?
      "absent de la page : #{missing.join(" | ")}#{danger(response)}"
    end

    def redirect?(response : ::HTTP::Client::Response, prefix : String = "/") : Bool | String
      return true if response.status_code == 302 && response.headers["Location"].starts_with?(prefix)
      "HTTP #{response.status_code}#{response.headers["Location"]?.try { |loc| " vers #{loc}" }}#{danger(response)}"
    end

    def danger(response : ::HTTP::Client::Response) : String
      blocks = response.body.scan(/<(?:ul|div|p|span)[^>]*(?:is-danger|pd-field-errors)[^>]*>(.*?)<\/(?:ul|div|p|span)>/m).map(&.[1])
      messages = blocks.flat_map { |block| HTML.unescape(block.gsub(/<[^>]+>/, "\n")).split('\n') }.map(&.strip).reject(&.empty?).uniq!
      messages.empty? ? "" : " — #{messages.first(4).join(" | ")}"
    end
  end

  # Démarre le serveur de Marten de la distribution dans ce processus, sur
  # 127.0.0.1:`port` (BLOCAGES B-UI-001 levé : le bac à sable autorise
  # désormais un port local).
  def self.serve(port : Int32) : Nil
    Marten.settings.host = "127.0.0.1"
    Marten.settings.port = port
    Marten::Server.setup
    spawn { Marten::Server.start }
    deadline = Time.instant + 30.seconds
    until listening?(port)
      raise "serveur non démarré sur le port #{port}" if Time.instant > deadline
      sleep 100.milliseconds
    end
  end

  def self.listening?(port : Int32) : Bool
    TCPSocket.new("127.0.0.1", port).close
    true
  rescue Socket::ConnectError
    false
  end
end
