# frozen_string_literal: true

# Check URLs, hosts or identifiers against a local aab_full.json.
#
#   ruby examples/check_urls.rb /var/lib/aab/aab_full.json https://api.example-agent.ai/run com.example.agentbrowser
#   tail -n 1000 /var/log/squid/access.log | ruby examples/check_urls.rb /var/lib/aab/aab_full.json -
#
# With "-" the script reads lines from STDIN and checks the first URL in each.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "aiagentblocklist"

json_path = ARGV.shift or abort "usage: check_urls.rb <aab_full.json> <url-or-id>... | -"
list = AiAgentBlocklist::Blocklist.from_file(json_path)

inputs =
  if ARGV == ["-"]
    $stdin.each_line.map { |line| line[%r{\b[a-z][a-z0-9+.\-]*://\S+}i] || line[/\b[\w.\-]+\.[a-z]{2,}(?=:\d+\b)/i] }.compact
  else
    ARGV
  end

inputs.each do |item|
  entry = list.check(item)
  if entry
    puts format("LISTED  %-45s %s | %s | %s", item, entry.tool_name, entry.agent_type, entry.kind)
  else
    puts format("ok      %s", item)
  end
end
