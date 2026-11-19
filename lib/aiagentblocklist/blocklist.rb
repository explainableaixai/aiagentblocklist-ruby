# frozen_string_literal: true

require "json"

module AiAgentBlocklist
  # The parsed aab_full.json feed. Lookup hashes are built once in the
  # constructor, so every check is a hash lookup (domains: one per label).
  class Blocklist
    include Enumerable

    EXTENSION_KINDS = %w[chrome_ext edge_ext firefox_ext vscode_ext openvsx_ext jetbrains_plugin].freeze
    PROCESS_KINDS = %w[process_cli process_mac process_win].freeze

    attr_reader :product, :version, :counts, :entries

    class << self
      # Parses the text of aab_full.json.
      def from_json(text)
        data = JSON.parse(text)
        raise Error, "aab_full.json must be a JSON object" unless data.is_a?(Hash)

        new(data)
      rescue JSON::ParserError => e
        raise Error, "aab_full.json is not valid JSON: #{e.message}"
      end

      # Reads a local aab_full.json, for example one kept current by Client#sync.
      def from_file(path)
        from_json(File.read(path, mode: "rb", encoding: "UTF-8"))
      rescue SystemCallError => e
        raise Error, "cannot read blocklist file #{path}: #{e.message}"
      end

      # Lowercase host from a URL or host: no scheme, user info, port, path,
      # query, fragment or trailing dot.
      def normalize_host(input)
        s = input.to_s.strip.downcase
        if (m = s.match(%r{\A[a-z][a-z0-9+.\-]*://}))
          s = s[m[0].length..]
        elsif s.start_with?("//")
          s = s[2..]
        end
        s = s.split(%r{[/?#\\]}, 2).first.to_s
        s = s[(s.rindex("@") + 1)..] if s.include?("@")
        if s.start_with?("[")
          close = s.index("]")
          s = close ? s[1...close] : s[1..]
        elsif s.include?(":")
          s = s[0...s.index(":")]
        end
        s.to_s.sub(/\.+\z/, "")
      end

      # PEP 503: lowercase, runs of "-", "_" and "." become one "-".
      def normalize_pypi(name)
        name.to_s.strip.gsub(/[-_.]+/, "-").downcase
      end

      def process_key(name)
        key = name.to_s.strip.downcase
        key.length > 4 && key.end_with?(".exe") ? key[0...-4] : key
      end
    end

    def initialize(data)
      rows = data["entries"]
      raise Error, 'not an AI Agent Blocklist document: "entries" is missing' unless rows.is_a?(Array)

      @product = data["product"].to_s
      @version = data["version"].to_s
      @counts = data["counts"].is_a?(Hash) ? data["counts"] : {}
      @entries = rows.select { |r| r.is_a?(Hash) }.map { |r| Entry.from_hash(r) }.freeze
      build_indexes
    end

    def each(&block)
      return enum_for(:each) unless block

      @entries.each(&block)
    end

    def size
      @entries.size
    end
    alias length size

    # Entry for the host or its nearest listed parent domain, or nil.
    # "api.example-agent.ai" matches "example-agent.ai"; "notexample-agent.ai" does not.
    def check_domain(host_or_url)
      host = self.class.normalize_host(host_or_url)
      until host.empty?
        hit = @by_domain[host]
        return hit if hit

        dot = host.index(".")
        return nil unless dot

        host = host[(dot + 1)..]
      end
      nil
    end

    # Exact, case-insensitive match over browser extension and IDE plugin IDs.
    def check_extension(id)
      @by_extension[id.to_s.strip.downcase]
    end

    # Case-insensitive process or command name; "tool.exe" and "tool" match each other.
    def check_process(name)
      @by_process[self.class.process_key(name)]
    end

    # +ecosystem+ is :npm or :pypi (string or symbol). PyPI names use PEP 503 normalisation.
    def check_package(ecosystem, name)
      case ecosystem.to_s.strip.downcase
      when "npm" then @by_npm[name.to_s.strip.downcase]
      when "pypi" then @by_pypi[self.class.normalize_pypi(name)]
      else raise ArgumentError, "unknown package ecosystem #{ecosystem.inspect} (use :npm or :pypi)"
      end
    end

    # Domain matching first, then an exact case-insensitive match on any identifier.
    def check(identifier)
      check_domain(identifier) || @by_ident[identifier.to_s.strip.downcase]
    end

    # Entries matching every given criterion (nil means any). Case-insensitive.
    def filter(agent_type: nil, kind: nil, risk_grade: nil)
      @entries.select do |e|
        same?(e.agent_type, agent_type) && same?(e.kind, kind) && same?(e.risk_grade, risk_grade)
      end
    end

    def domains
      @by_domain.keys.sort
    end

    def agent_types
      distinct(:agent_type)
    end

    def kinds
      distinct(:kind)
    end

    def inspect
      "#<#{self.class.name} version=#{@version.inspect} entries=#{@entries.size}>"
    end

    private

    def same?(value, wanted)
      wanted.nil? || value.casecmp?(wanted.to_s)
    end

    def distinct(field)
      @entries.map(&field).reject(&:empty?).uniq.sort
    end

    def build_indexes
      @by_domain = {}
      @by_extension = {}
      @by_process = {}
      @by_npm = {}
      @by_pypi = {}
      @by_ident = {}
      @entries.each { |e| index(e) }
      [@by_domain, @by_extension, @by_process, @by_npm, @by_pypi, @by_ident].each(&:freeze)
    end

    def index(entry)
      ident = entry.ident.strip
      return if ident.empty?

      lower = ident.downcase
      @by_ident[lower] ||= entry
      case entry.kind
      when "domain"
        host = self.class.normalize_host(ident)
        @by_domain[host] ||= entry unless host.empty?
      when *EXTENSION_KINDS then @by_extension[lower] ||= entry
      when *PROCESS_KINDS then @by_process[self.class.process_key(ident)] ||= entry
      when "npm" then @by_npm[lower] ||= entry
      when "pypi" then @by_pypi[self.class.normalize_pypi(ident)] ||= entry
      end
    end
  end
end
