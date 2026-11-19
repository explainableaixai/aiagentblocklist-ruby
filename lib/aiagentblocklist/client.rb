# frozen_string_literal: true

require "net/http"
require "uri"
require "fileutils"
require "securerandom"

module AiAgentBlocklist
  # Feed client. There is no lookup API: the client fetches the files behind
  # your private download link, keeps local copies current with conditional
  # requests and parses aab_full.json so checks run in your own process.
  class Client
    DEFAULT_BASE_URL = "https://www.aiagentblocklist.com"
    DEFAULT_TIMEOUT = 30
    TOKEN_ENV = "AIAGENTBLOCKLIST_TOKEN"
    USER_AGENT = "aiagentblocklist-ruby/#{VERSION} (+https://www.aiagentblocklist.com)"
    TOKEN_PATTERN = /\A[A-Za-z0-9]{32}\z/.freeze
    FILE_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_]*\.(csv|json|txt|pac|zone|reg|mobileconfig)\z/.freeze

    # Every file published behind a download link.
    FILES = %w[
      aab_full.csv aab_full.json domains.txt firewall_edl.txt hosts.txt proxy.pac dns_rpz.zone
      chrome_extension_blocklist.json edge_extension_blocklist.json
      chrome_edge_extension_blocklist.reg chrome_edge_extensions.mobileconfig
      firefox_extension_ids.txt macos_bundle_ids.txt windows_package_ids.txt process_names.txt
      npm_packages.txt pypi_packages.txt counts.json README.txt
    ].freeze

    attr_reader :base_url, :timeout, :user_agent

    # token:: the 32 letters and digits from your download link; nil reads
    #         ENV["AIAGENTBLOCKLIST_TOKEN"].
    # base_url::, timeout:: (seconds), user_agent:: optional overrides.
    # transport:: optional callable (method, uri, headers, timeout) returning
    #             [status, headers_hash, body]; replaces Net::HTTP in tests.
    #
    # Raises TokenError before any request when the token is missing or malformed.
    def initialize(token = nil, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT,
                   user_agent: USER_AGENT, transport: nil)
      token = ENV.fetch(TOKEN_ENV, "") if token.nil? || token.to_s.strip.empty?
      token = token.to_s.strip
      raise TokenError, "no token: pass one or set #{TOKEN_ENV}" if token.empty?
      unless TOKEN_PATTERN.match?(token)
        raise TokenError, "the token must be exactly 32 letters and digits, as in your download link"
      end

      @token = token
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @timeout = timeout
      @user_agent = user_agent
      @transport = transport || method(:net_http_transport)
    end

    # URL of the HTML page that lists your files.
    def file_list_url
      "#{@base_url}/download/#{@token}/"
    end

    # Full URL of one file. Raises Error for names outside the published pattern.
    def file_url(name)
      file_list_url + self.class.check_file_name(name)
    end

    # Body of one file as a binary String.
    def download(name)
      request(name)[2]
    end

    # Conditional GET into +path+. The ETag lives in "#{path}.etag" and goes
    # out as If-None-Match next time. Returns false when nothing changed
    # (304, or the same bare ETag on a 200) and true after an atomic write.
    def download_to(name, path)
      self.class.check_file_name(name)
      path = path.to_s
      sidecar = "#{path}.etag"
      stored = File.file?(path) && File.file?(sidecar) ? File.read(sidecar).strip : ""

      headers = stored.empty? ? {} : { "If-None-Match" => stored }
      status, response_headers, body = request(name, headers)
      return false if status == 304

      etag = response_headers["etag"].to_s.strip
      return false if !stored.empty? && !etag.empty? && self.class.bare_etag(etag) == self.class.bare_etag(stored)

      self.class.write_atomic(path, body)
      self.class.write_atomic(sidecar, etag)
      true
    end

    # Fetches each name into +dir+ and returns { name => updated? }.
    # All names are checked before the first request.
    def sync(dir, names = FILES)
      names = Array(names).map(&:to_s)
      names.each { |n| self.class.check_file_name(n) }
      FileUtils.mkdir_p(dir)
      names.each_with_object({}) do |name, out|
        out[name] = download_to(name, File.join(dir.to_s, name))
      end
    end

    # Downloads aab_full.json and returns a Blocklist.
    def load_blocklist
      Blocklist.from_json(download("aab_full.json").force_encoding(Encoding::UTF_8))
    end

    def inspect
      "#<#{self.class.name} base_url=#{@base_url.inspect} token=[hidden]>"
    end

    class << self
      def check_file_name(name)
        name = name.to_s
        return name if FILE_PATTERN.match?(name)

        raise Error, "invalid file name #{name.inspect}: expected a name like domains.txt or aab_full.json"
      end

      # ETag without W/, quotes or a -gzip suffix.
      def bare_etag(etag)
        e = etag.to_s.strip
        e = e[2..] if e.start_with?("W/", "w/")
        e = e.delete_prefix('"').delete_suffix('"')
        e.end_with?("-gzip") ? e[0...-5] : e
      end

      # Writes to a temp file in the same folder, then renames it over +path+.
      def write_atomic(path, data)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        tmp = File.join(dir, ".aab-#{Process.pid}-#{SecureRandom.hex(6)}")
        File.open(tmp, "wb") { |f| f.write(data) }
        File.rename(tmp, path)
      rescue SystemCallError => e
        raise Error, "cannot write #{path}: #{e.message}"
      end
    end

    private

    def request(name, extra_headers = {})
      uri = URI(file_url(name))
      headers = { "User-Agent" => @user_agent, "Accept" => "*/*" }.merge(extra_headers)
      begin
        status, raw_headers, body = @transport.call("GET", uri, headers, @timeout)
      rescue Error
        raise
      rescue StandardError, Timeout::Error => e
        raise Error, "network error while fetching #{name}: #{e.message}"
      end

      status = status.to_i
      response_headers = (raw_headers || {}).each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = Array(v).join(", ") }
      return [status, response_headers, body.to_s] if (200..299).cover?(status) || status == 304

      case status
      when 404 then raise NotFoundError.new("not found (404) for #{name}: the token or the file name is unknown", status: 404)
      when 403 then raise AccessEndedError.new("access ended (403): the subscription for this token has ended or is paused", status: 403)
      else raise HttpError.new("unexpected HTTP #{status} while fetching #{name}", status: status)
      end
    end

    # Default transport. Net::HTTP picks up http_proxy / https_proxy from ENV.
    def net_http_transport(method, uri, headers, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      request = Net::HTTPGenericRequest.new(method, false, method != "HEAD", uri.request_uri, headers)
      response = http.start { |conn| conn.request(request) }
      [response.code.to_i, response.each_header.to_h, response.body]
    end
  end
end
