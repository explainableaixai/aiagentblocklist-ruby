# frozen_string_literal: true

# Rake tasks for a Rails app. Copy to lib/tasks/aiagentblocklist.rake.
#
#   bin/rails aab:sync                 # fetch changed feed files into storage/aab
#   bin/rails "aab:report[log/proxy.log]"  # count requests to listed hosts
#
# The token comes from AIAGENTBLOCKLIST_TOKEN or Rails credentials.

namespace :aab do
  desc "Sync the AI Agent Blocklist files into storage/aab"
  task sync: :environment do
    require "aiagentblocklist"

    token = ENV["AIAGENTBLOCKLIST_TOKEN"] || Rails.application.credentials.dig(:aiagentblocklist, :token)
    client = AiAgentBlocklist::Client.new(token)
    dir = Rails.root.join("storage", "aab")
    files = %w[aab_full.json domains.txt firewall_edl.txt chrome_extension_blocklist.json]

    begin
      client.sync(dir, files).each do |name, updated|
        puts "#{name.ljust(34)} #{updated ? 'updated' : 'unchanged'}"
      end
    rescue AiAgentBlocklist::AccessEndedError
      warn "AI Agent Blocklist: subscription ended or paused, keeping the last files"
      exit 2
    end
  end

  desc "Count requests to listed AI agent hosts in a log file"
  task :report, [:log] => :environment do |_t, args|
    require "aiagentblocklist"

    list = AiAgentBlocklist::Blocklist.from_file(Rails.root.join("storage", "aab", "aab_full.json"))
    counts = Hash.new(0)
    File.foreach(args.fetch(:log)) do |line|
      url = line[%r{\bhttps?://\S+}] or next
      entry = list.check_domain(url) or next
      counts[[AiAgentBlocklist::Blocklist.normalize_host(url), entry.agent_type]] += 1
    end
    counts.sort_by { |_, n| -n }.each { |(host, type), n| puts format("%6d  %-40s %s", n, host, type) }
  end
end
