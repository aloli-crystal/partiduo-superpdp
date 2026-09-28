# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "http/client"
require "openssl"
require "socket"
require "uri"

module Superpdp
  module SpecSupport
    # Transport réel à travers un mandataire HTTP (`HTTPS_PROXY`), pour la
    # suite d'intégration seulement : tunnel `CONNECT`, puis TLS *vérifié*
    # (certificat et nom d'hôte) jusqu'à SUPER PDP. Le transport réseau
    # d'EINV (`Einvoicing::Http::NetTransport`) ne suit pas `HTTPS_PROXY`
    # (BLOCAGES B-SPDP-001).
    class ProxyTransport < Einvoicing::Http::Transport
      TIMEOUT = 60.seconds

      def self.from_env : ProxyTransport?
        value = ENV["HTTPS_PROXY"]?.presence || ENV["https_proxy"]?.presence
        value.try { |text| new(URI.parse(text)) }
      end

      def initialize(@proxy : URI)
      end

      def exec(request : Einvoicing::Http::Request) : Einvoicing::Http::Response
        uri = URI.parse(request.url)
        raise Einvoicing::ConnectorError.new("adresse non HTTPS refusée : #{request.url}") unless uri.scheme == "https"
        host = uri.host.to_s
        port = uri.port || 443
        # `localhost` peut se résoudre en `::1`, où le mandataire n'écoute pas.
        proxy_host = @proxy.host == "localhost" ? "127.0.0.1" : @proxy.host.to_s
        socket = TCPSocket.new(proxy_host, @proxy.port || 80, connect_timeout: TIMEOUT)
        socket.read_timeout = TIMEOUT
        socket << "CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n"
        if user = @proxy.user
          credentials = Base64.strict_encode("#{URI.decode(user)}:#{URI.decode(@proxy.password.to_s)}")
          socket << "Proxy-Authorization: Basic #{credentials}\r\n"
        end
        socket << "\r\n"
        socket.flush
        status = socket.gets.to_s
        raise Einvoicing::ConnectorError.new("mandataire : #{status}") unless status.split(' ')[1]? == "200"
        while line = socket.gets
          break if line.strip.empty?
        end
        tls = OpenSSL::SSL::Socket::Client.new(socket, OpenSSL::SSL::Context::Client.new, sync_close: true, hostname: host)
        headers = HTTP::Headers{"Host" => host, "Connection" => "close"}
        request.headers.each { |name, value| headers[name] = value }
        body = request.body
        headers["Content-Length"] = (body.try(&.size) || 0).to_s if body || request.method != "GET"
        HTTP::Request.new(request.method, uri.request_target, headers, body.try { |bytes| IO::Memory.new(bytes) }).to_io(tls)
        tls.flush
        response = HTTP::Client::Response.from_io(tls, ignore_body: false, decompress: true)
        result = {} of String => String
        response.headers.each { |name, values| result[name.downcase] = values.join(", ") }
        Einvoicing::Http::Response.new(response.status_code, result, response.body.to_slice)
      rescue ex : Einvoicing::ConnectorError
        raise ex
      rescue ex
        # Réponse tronquée par le mandataire (« Unexpected end of http
        # request ») comprise.
        raise Einvoicing::ConnectorError.new("#{uri.try(&.host)} injoignable par le mandataire : #{ex.message}")
      ensure
        tls.try(&.close) rescue nil
        socket.try(&.close) rescue nil
      end
    end
  end
end
