# frozen_string_literal: true

require_relative "lib/aiagentblocklist/version"

Gem::Specification.new do |spec|
  spec.name          = "aiagentblocklist"
  spec.version       = AiAgentBlocklist::VERSION
  spec.authors       = ["Alpha Quantum"]
  spec.email         = ["info@alpha-quantum.com"]

  spec.summary       = "Ruby feed client for the AI agent blocklist from aiagentblocklist.com."
  spec.description   = "Keeps the daily AI Agent Blocklist files in sync with conditional downloads and checks " \
                       "domains, browser extension IDs, process names and npm or PyPI packages in memory. " \
                       "For Rails apps, rake tasks and background jobs. Uses only net/http and json from the standard library."
  spec.homepage      = "https://www.aiagentblocklist.com"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.7"

  spec.metadata = {
    "homepage_uri" => "https://www.aiagentblocklist.com",
    "source_code_uri" => "https://github.com/explainableaixai/aiagentblocklist-ruby",
    "changelog_uri" => "https://github.com/explainableaixai/aiagentblocklist-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://www.aiagentblocklist.com/contact.php",
    "documentation_uri" => "https://github.com/explainableaixai/aiagentblocklist-ruby#readme",
    "rubygems_mfa_required" => "true"
  }
  # Keywords: ai-agents, ai-agent-blocklist, blocklist, ai-browser, mcp, coding-agents,
  # browser-extensions, dns-filtering, firewall, edl, shadow-ai, ai-governance, threat-feed

  spec.files = Dir["lib/**/*.rb", "examples/*.{rb,rake}", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
