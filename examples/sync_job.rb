# frozen_string_literal: true

# Sidekiq job that keeps storage/aab current. Copy to app/sidekiq/aab_sync_job.rb
# and schedule it, for example with sidekiq-cron:
#
#   Sidekiq::Cron::Job.create(name: "AI Agent Blocklist sync", cron: "20 * * * *", class: "AabSyncJob")
#
# Hourly is fine: unchanged files cost one 304 each. AgentLinkGuard reloads
# aab_full.json when its modification time changes.

require "aiagentblocklist"

class AabSyncJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 5

  FILES = %w[aab_full.json domains.txt firewall_edl.txt hosts.txt].freeze

  def perform
    client = AiAgentBlocklist::Client.new(ENV["AIAGENTBLOCKLIST_TOKEN"], timeout: 60)
    changed = client.sync(Rails.root.join("storage", "aab"), FILES).select { |_, updated| updated }.keys
    Rails.logger.info("[aab] updated: #{changed.join(', ')}") unless changed.empty?
  rescue AiAgentBlocklist::AccessEndedError, AiAgentBlocklist::NotFoundError => e
    # Retrying will not help; keep the last good files and tell someone.
    Rails.logger.error("[aab] #{e.class}: #{e.message}")
  end
end
