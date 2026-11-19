# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "tmpdir"
require "aiagentblocklist"

# Offline: a fake transport answers every request and the feed is a fixture
# with made-up entries.
class TestAiAgentBlocklist < Minitest::Test
  TOKEN = "abcdEFGH1234abcdEFGH1234abcdEFGH"
  FIXTURE = File.read(File.expand_path("fixtures/aab_full.json", __dir__))

  def client(&handler)
    AiAgentBlocklist::Client.new(TOKEN, transport: ->(method, uri, headers, _timeout) { handler.call(method, uri, headers) })
  end

  def list
    @list ||= AiAgentBlocklist::Blocklist.from_json(FIXTURE)
  end

  def tmpdir
    Dir.mktmpdir("aab-ruby-test-")
  end

  # Token and file names

  def test_token_from_environment
    old = ENV[AiAgentBlocklist::Client::TOKEN_ENV]
    ENV[AiAgentBlocklist::Client::TOKEN_ENV] = TOKEN
    c = AiAgentBlocklist::Client.new
    assert_equal "https://www.aiagentblocklist.com/download/#{TOKEN}/domains.txt", c.file_url("domains.txt")
    refute_includes c.inspect, TOKEN
  ensure
    ENV[AiAgentBlocklist::Client::TOKEN_ENV] = old
  end

  def test_bad_tokens_raise_before_any_request
    old = ENV.delete(AiAgentBlocklist::Client::TOKEN_ENV)
    called = false
    transport = ->(*) { called = true }
    ["", "abc123", "#{TOKEN}x", "abcdEFGH1234abcdEFGH1234abcdEF-!", "#{TOKEN}\nX"].each do |bad|
      err = assert_raises(AiAgentBlocklist::TokenError) { AiAgentBlocklist::Client.new(bad, transport: transport) }
      assert_kind_of AiAgentBlocklist::Error, err
      assert_nil err.status
    end
    refute called
  ensure
    ENV[AiAgentBlocklist::Client::TOKEN_ENV] = old if old
  end

  def test_file_url_and_list_url
    c = AiAgentBlocklist::Client.new(TOKEN, base_url: "http://127.0.0.1:9000/")
    assert_equal "http://127.0.0.1:9000/download/#{TOKEN}/", c.file_list_url
    assert_equal "http://127.0.0.1:9000/download/#{TOKEN}/dns_rpz.zone", c.file_url("dns_rpz.zone")
    assert_equal "README.txt", AiAgentBlocklist::Client.check_file_name("README.txt")
  end

  def test_bad_file_names_are_rejected_without_request
    c = client { flunk "no request expected" }
    ["../etc/passwd", "a/b.txt", "_x.txt", "my-file.txt", "domains.exe", "domains", "domains.txt?x", "domains.txt\n"].each do |bad|
      assert_raises(AiAgentBlocklist::Error) { c.download(bad) }
    end
  end

  # HTTP behaviour

  def test_download_sends_user_agent
    seen = nil
    c = client do |method, uri, headers|
      seen = [method, uri.to_s, headers]
      [200, { "ETag" => '"v1"' }, "example-agent.ai\n"]
    end
    assert_equal "example-agent.ai\n", c.download("domains.txt")
    assert_equal "GET", seen[0]
    assert seen[1].end_with?("/download/#{TOKEN}/domains.txt")
    assert_equal "aiagentblocklist-ruby/1.0.0 (+https://www.aiagentblocklist.com)", seen[2]["User-Agent"]
  end

  def test_status_codes_map_to_errors
    { 404 => AiAgentBlocklist::NotFoundError, 403 => AiAgentBlocklist::AccessEndedError,
      500 => AiAgentBlocklist::HttpError, 429 => AiAgentBlocklist::HttpError }.each do |status, klass|
      c = client { [status, {}, "nope"] }
      err = assert_raises(klass) { c.download("hosts.txt") }
      assert_equal status, err.status
      assert_kind_of AiAgentBlocklist::Error, err
      refute_includes err.message, TOKEN
    end
  end

  def test_network_errors_are_wrapped
    c = client { raise Errno::ECONNREFUSED }
    err = assert_raises(AiAgentBlocklist::Error) { c.download("counts.json") }
    assert_nil err.status
    assert_match(/refused/i, err.message)
  end

  # Conditional downloads

  def test_download_to_writes_sidecar_then_sends_if_none_match
    dir = tmpdir
    path = File.join(dir, "domains.txt")
    sent = []
    c = client do |_m, _u, headers|
      sent << headers
      headers["If-None-Match"] == '"abc123"' ? [304, {}, ""] : [200, { "etag" => '"abc123"' }, "example-agent.ai\n"]
    end

    assert c.download_to("domains.txt", path)
    assert_equal "example-agent.ai\n", File.read(path)
    assert_equal '"abc123"', File.read("#{path}.etag")
    refute sent[0].key?("If-None-Match")

    refute c.download_to("domains.txt", path)
    assert_equal '"abc123"', sent[1]["If-None-Match"]
    assert_equal "example-agent.ai\n", File.read(path)
    assert_empty Dir.glob(File.join(dir, ".aab-*"))
  end

  def test_weak_gzip_etag_counts_as_unchanged
    dir = tmpdir
    path = File.join(dir, "hosts.txt")
    File.write(path, "0.0.0.0 example-agent.ai\n")
    File.write("#{path}.etag", '"5f2-63a"')
    c = client { [200, { "etag" => 'W/"5f2-63a-gzip"' }, "changed\n"] }
    refute c.download_to("hosts.txt", path)
    assert_equal "0.0.0.0 example-agent.ai\n", File.read(path)
  end

  def test_new_etag_replaces_the_file
    dir = tmpdir
    path = File.join(dir, "hosts.txt")
    File.write(path, "old\n")
    File.write("#{path}.etag", '"v1"')
    c = client { [200, { "ETag" => '"v2"' }, "new\n"] }
    assert c.download_to("hosts.txt", path)
    assert_equal "new\n", File.read(path)
    assert_equal '"v2"', File.read("#{path}.etag")
  end

  def test_sidecar_ignored_when_file_missing
    dir = tmpdir
    path = File.join(dir, "proxy.pac")
    File.write("#{path}.etag", '"stale"')
    sent = nil
    c = client do |_m, _u, headers|
      sent = headers
      [200, { "etag" => '"stale"' }, "function FindProxyForURL(u, h) { return \"DIRECT\"; }"]
    end
    assert c.download_to("proxy.pac", path)
    refute sent.key?("If-None-Match")
    assert File.file?(path)
  end

  def test_bare_etag
    assert_equal "abc", AiAgentBlocklist::Client.bare_etag('W/"abc-gzip"')
    assert_equal "abc", AiAgentBlocklist::Client.bare_etag('"abc"')
    assert_equal "abc", AiAgentBlocklist::Client.bare_etag(" abc ")
  end

  def test_sync_returns_updated_map
    dir = File.join(tmpdir, "feed")
    c = client do |_m, uri, headers|
      headers["If-None-Match"] == '"same"' ? [304, {}, ""] : [200, { "etag" => '"same"' }, "#{File.basename(uri.path)}\n"]
    end
    assert_equal({ "domains.txt" => true, "aab_full.json" => true }, c.sync(dir, %w[domains.txt aab_full.json]))
    assert_equal "aab_full.json\n", File.read(File.join(dir, "aab_full.json"))
    assert_equal({ "domains.txt" => false, "aab_full.json" => false }, c.sync(dir, %w[domains.txt aab_full.json]))
    assert_equal 19, AiAgentBlocklist::Client::FILES.size
  end

  def test_sync_validates_all_names_first
    c = client { flunk "no request expected" }
    assert_raises(AiAgentBlocklist::Error) { c.sync(tmpdir, ["domains.txt", "../x.txt"]) }
  end

  def test_load_blocklist
    c = client { [200, {}, FIXTURE.dup.force_encoding(Encoding::BINARY)] }
    bl = c.load_blocklist
    assert_equal "fixture-1", bl.version
    assert_equal 12, bl.size
  end

  # Blocklist

  def test_from_file_and_metadata
    bl = AiAgentBlocklist::Blocklist.from_file(File.expand_path("fixtures/aab_full.json", __dir__))
    assert_equal "AI Agent Blocklist", bl.product
    assert_equal 12, bl.counts["total"]
    assert(bl.entries.all? { |e| e.is_a?(AiAgentBlocklist::Entry) })
    assert_equal 12, bl.count
  end

  def test_invalid_documents
    assert_raises(AiAgentBlocklist::Error) { AiAgentBlocklist::Blocklist.from_json('{"product": "x"}') }
    assert_raises(AiAgentBlocklist::Error) { AiAgentBlocklist::Blocklist.from_json("not json") }
    assert_raises(AiAgentBlocklist::Error) { AiAgentBlocklist::Blocklist.from_file("/nonexistent/aab_full.json") }
  end

  def test_domain_suffix_matching
    assert_equal "Example Agent", list.check_domain("example-agent.ai").tool_name
    assert_equal "Example Agent", list.check_domain("api.example-agent.ai").tool_name
    assert_equal "Example Agent", list.check_domain("a.b.c.example-agent.ai").tool_name
    assert_nil list.check_domain("notexample-agent.ai")
    assert_nil list.check_domain("example-agent.ai.other.test")
    assert_nil list.check_domain("ai")
    assert_nil list.check_domain("")
  end

  def test_url_normalisation
    {
      "https://API.Example-Agent.ai/v1/run?x=1#top" => "api.example-agent.ai",
      "http://user:secret@sample-browser.app:8443/path" => "sample-browser.app",
      "sample-browser.app." => "sample-browser.app",
      "  Demo-MCP-Server.dev:443  " => "demo-mcp-server.dev",
      "//cdn.example-agent.ai/x.js" => "cdn.example-agent.ai",
      "wss://live.sample-browser.app/socket" => "live.sample-browser.app"
    }.each do |input, host|
      assert_equal host, AiAgentBlocklist::Blocklist.normalize_host(input)
      refute_nil list.check_domain(input), input
    end
  end

  def test_only_domain_kind_counts_for_domains
    assert_nil list.check_domain("com.example.agentbrowser")
    assert_equal %w[demo-mcp-server.dev example-agent.ai sample-browser.app], list.domains
  end

  def test_extensions
    assert_equal "chrome_ext", list.check_extension("ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP").kind
    assert_equal "firefox_ext", list.check_extension("agent-helper@example.org").kind
    assert_equal "vscode_ext", list.check_extension("examplecorp.example-coder").kind
    assert_nil list.check_extension("abcdefghijklmnopabcdefghijklmno")
    assert_nil list.check_extension("example-agent.ai")
  end

  def test_processes_with_exe
    assert_equal "process_win", list.check_process("samplebrowser").kind
    assert_equal "process_win", list.check_process("SAMPLEBROWSER.EXE").kind
    assert_equal "process_cli", list.check_process("example-coder.exe").kind
    assert_equal "process_mac", list.check_process("sample browser helper").kind
    assert_nil list.check_process("example")
  end

  def test_packages
    assert_equal "npm", list.check_package(:npm, "Demo-MCP-Server").kind
    assert_nil list.check_package(:npm, "demo_mcp_server")
    assert_equal "pypi", list.check_package("pypi", "demo-mcp-server").kind
    assert_equal "pypi", list.check_package("PyPI", "DEMO__mcp..server").kind
    assert_equal "demo-mcp-server", AiAgentBlocklist::Blocklist.normalize_pypi("Demo_MCP.Server")
    assert_raises(ArgumentError) { list.check_package(:cargo, "demo") }
  end

  def test_check_tries_domain_then_ident
    assert_equal "domain", list.check("https://www.sample-browser.app/download").kind
    assert_equal "mac_bundle_id", list.check("COM.EXAMPLE.AGENTBROWSER").kind
    assert_equal "firefox_ext", list.check("agent-helper@example.org").kind
    assert_equal "process_win", list.check("SampleBrowser.exe").kind
    assert_nil list.check("nothing-here.example")
  end

  def test_filter_and_facets
    assert_equal 4, list.filter(agent_type: "AI browser").size
    assert_equal 1, list.filter(agent_type: "ai browser", kind: "domain").size
    assert_equal 3, list.filter(risk_grade: "High").size
    assert_equal 2, list.filter(agent_type: "Coding agent", risk_grade: "Not graded").size
    assert_empty list.filter(agent_type: "Voice agent")
    assert_equal ["AI browser", "Browser agent", "Coding agent", "MCP server"], list.agent_types
    assert_equal %w[chrome_ext domain firefox_ext mac_bundle_id npm process_cli process_mac process_win pypi vscode_ext],
                 list.kinds
  end

  def test_entry_json_round_trip
    entry = list.check_domain("example-agent.ai")
    back = JSON.parse(entry.to_json)
    assert_equal AiAgentBlocklist::Entry.members.map(&:to_s), back.keys
    assert_equal entry, AiAgentBlocklist::Entry.from_hash(back)
    assert entry.domain?
  end
end
