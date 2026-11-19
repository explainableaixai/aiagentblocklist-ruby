# aiagentblocklist

A small Ruby gem for putting the AI Agent Blocklist to work inside Rails apps, rake tasks and background jobs. It pulls the daily feed from your private download link, saves it next to your app, and answers questions like "is this URL an AI agent?" or "is this npm package an MCP server we have not approved?" without leaving the Ruby process.

The gem uses `net/http` and `json` from the standard library and nothing else. No new transitive dependencies end up in your `Gemfile.lock`.

## At a glance

| Question | Answer |
|---|---|
| What is in the feed? | 2,600+ AI agent domains and 5,300+ device identifiers |
| How often does it change? | a new build arrives every day at the same URLs |
| What kinds of identifiers? | domains; extension IDs for browsers and IDEs; bundle IDs on the Mac; package IDs on Windows; process names; npm, PyPI and Homebrew names |
| How does the gem talk to the server? | plain file downloads with ETag caching; there is no query API |
| Where do checks run? | in memory, in your process, using hashes built when the JSON loads |
| Ruby version | 2.7 or newer |
| License | MIT |

## Installation

Add it to your Gemfile:

```ruby
gem "aiagentblocklist", "~> 1.0"
```

Or install it directly:

```bash
gem install aiagentblocklist
```

The client needs the 32-character token from your download link. Pass it to `AiAgentBlocklist::Client.new`, or export `AIAGENTBLOCKLIST_TOKEN` and call `new` with no argument. In Rails, credentials are a tidy home for it:

```bash
bin/rails credentials:edit
# aiagentblocklist:
#   token: YOUR32CHARACTERTOKENGOESHERE0000
```

You can find subscription options on the [pricing page](https://www.aiagentblocklist.com/pricing.php).

## First steps in irb

```ruby
require "aiagentblocklist"

client = AiAgentBlocklist::Client.new          # token from ENV
client.sync("tmp/aab", %w[aab_full.json domains.txt])
# => {"aab_full.json"=>true, "domains.txt"=>true}

list = AiAgentBlocklist::Blocklist.from_file("tmp/aab/aab_full.json")
list.size                                       # number of entries
list.check_domain("https://app.example-agent.ai/login")&.agent_type
# => "Browser agent"
list.check_extension("ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP")&.kind
# => "chrome_ext"
list.check_package(:pypi, "demo_mcp.server")&.tool_name
# => "Demo MCP Server"
list.filter(agent_type: "MCP server").map(&:ident)
```

Every name above is a placeholder, chosen so the snippets read clearly. Run the second `sync` and you get `false` for both files, because the server answered 304 and nothing was rewritten.

## The problem we are solving

An AI agent is software that acts on its own: it browses, clicks, types, reads files and calls other services. An AI browser bundles that ability into the browser itself. Either way, the agent works with whatever the person in front of it can reach, from their mail and calendar to customer records and production consoles.

When those tools arrive without review, security teams learn about them late. The usual signs are odd traffic in a proxy, an unknown extension in a browser report, or a coding assistant that started its own local server. Our page on [shadow AI agents](https://www.aiagentblocklist.com/ai-agents/shadow-ai-agents.php) describes how this tends to unfold inside a company.

A shared list makes one decision usable everywhere. The firewall and DNS can refuse the domains, MDM can refuse the apps, browser policy can refuse the extensions, and your Rails code can refuse the links and package names that come in through forms and APIs. [MITRE ATLAS](https://atlas.mitre.org/) is a good map of the techniques that make unreviewed agents a concern.

## Recipe 1: a Rails controller concern

This concern refuses form fields that point at a listed AI agent domain. It fits link sharing, bookmark tools, LMS resource pages, and redirect endpoints.

```ruby
# app/controllers/concerns/agent_link_guard.rb
module AgentLinkGuard
  extend ActiveSupport::Concern

  class_methods do
    def guard_agent_links(*fields, **options)
      before_action(**options) { refuse_agent_links(fields) }
    end
  end

  def self.blocklist
    path = Rails.root.join("storage/aab/aab_full.json").to_s
    mtime = File.mtime(path)
    @mutex ||= Mutex.new
    @mutex.synchronize do
      @list = nil if @mtime != mtime
      @mtime = mtime
      @list ||= AiAgentBlocklist::Blocklist.from_file(path)
    end
  end

  private

  def refuse_agent_links(fields)
    fields.each do |field|
      value = params[field]
      next unless value.is_a?(String)

      if (entry = AgentLinkGuard.blocklist.check_domain(value))
        render plain: "#{entry.tool_name} links need approval first.", status: :unprocessable_entity
        return
      end
    end
  end
end
```

```ruby
class BookmarksController < ApplicationController
  include AgentLinkGuard
  guard_agent_links :url, only: %i[create update]
end
```

The concern reloads the JSON whenever its modification time changes, so a sync from a rake task or a job shows up in every Puma worker without a restart. The longer version in `examples/agent_link_guard.rb` also reads nested params such as `bookmark.url`.

## Recipe 2: rake tasks

Two tasks cover most needs: one keeps the files current and one reports what a log contains. Copy `examples/aiagentblocklist.rake` to `lib/tasks/`.

```ruby
namespace :aab do
  desc "Sync the AI Agent Blocklist into storage/aab"
  task sync: :environment do
    token = Rails.application.credentials.dig(:aiagentblocklist, :token)
    client = AiAgentBlocklist::Client.new(token)
    files = %w[aab_full.json domains.txt firewall_edl.txt chrome_extension_blocklist.json]

    client.sync(Rails.root.join("storage/aab"), files).each do |name, updated|
      puts "#{name.ljust(34)} #{updated ? 'updated' : 'unchanged'}"
    end
  rescue AiAgentBlocklist::AccessEndedError
    abort "Subscription ended or paused. The last files stay in storage/aab."
  end
end
```

```bash
bin/rails aab:sync
bin/rails "aab:report[log/proxy.log]"
```

The report task counts requests per listed host and prints the agent type next to each one. That is a quick way to build the first draft of an [AI agent inventory](https://www.aiagentblocklist.com/ai-agents/ai-agent-inventory.php) from data you already have.

On servers without Rails, the same sync is a one-liner for cron:

```bash
ruby -raiagentblocklist -e 'AiAgentBlocklist::Client.new.sync("/var/lib/aab")'
```

## Recipe 3: a Sidekiq job on a schedule

Apps that already run Sidekiq can keep the feed current without cron. The job below runs hourly, logs what changed, and gives up quietly on errors that a retry will not fix.

```ruby
# app/sidekiq/aab_sync_job.rb
class AabSyncJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 5

  FILES = %w[aab_full.json domains.txt firewall_edl.txt hosts.txt].freeze

  def perform
    client = AiAgentBlocklist::Client.new(ENV["AIAGENTBLOCKLIST_TOKEN"], timeout: 60)
    changed = client.sync(Rails.root.join("storage/aab"), FILES).select { |_, v| v }.keys
    Rails.logger.info("[aab] updated #{changed.join(', ')}") if changed.any?
  rescue AiAgentBlocklist::AccessEndedError, AiAgentBlocklist::NotFoundError => e
    Rails.logger.error("[aab] #{e.class}: #{e.message}")
  end
end
```

```ruby
# config/initializers/sidekiq_cron.rb (with the sidekiq-cron gem)
Sidekiq::Cron::Job.create(name: "aab sync", cron: "20 * * * *", class: "AabSyncJob")
```

Network blips and 5xx answers raise `AiAgentBlocklist::Error` or `HttpError`, which Sidekiq retries with its usual backoff. A 403 or 404 is rescued, because those need a person to act on the subscription or the token. Active Job works the same way if you prefer it to Sidekiq.

Sidekiq, Rails and the other names in these recipes stay with their owners. Product names are trademarks of their respective owners.

## Recipe 4: auditing a repository for agent packages

Coding agents and MCP servers often arrive as packages. A small script can read a project's manifests and flag names that appear in the feed.

```ruby
require "json"
require "aiagentblocklist"

list = AiAgentBlocklist::Blocklist.from_file("/var/lib/aab/aab_full.json")

npm = JSON.parse(File.read("package.json")).values_at("dependencies", "devDependencies").compact.flat_map(&:keys)
pypi = File.exist?("requirements.txt") ? File.readlines("requirements.txt").map { |l| l[/\A[A-Za-z0-9._-]+/] }.compact : []

npm.each  { |n| (e = list.check_package(:npm, n))  && puts("npm  #{n}: #{e.agent_type}") }
pypi.each { |n| (e = list.check_package(:pypi, n)) && puts("pypi #{n}: #{e.agent_type}") }
```

Run it in CI and fail the build on a hit, or just print a warning for a reviewer. The [coding agent risk overview](https://www.aiagentblocklist.com/coding-agents/coding-agent-security-risks.php) explains why these packages deserve a second look.

## What happens during a sync

It helps to know the exact steps when you read logs or debug a job:

1. The gem checks every file name against the published pattern. A typo fails here, before any request.
2. For each file, it looks for both the local copy and its `.etag` sidecar. Only when both exist does it send `If-None-Match`.
3. A 304 answer ends the step. The file and the sidecar stay untouched and the result for that name is `false`.
4. A 200 answer is compared by bare ETag first. Some servers add `W/` or a `-gzip` suffix, and the gem treats those as the same version.
5. A new version goes to a hidden temp file in the same folder and is then renamed over the old one. The sidecar is written the same way.
6. Any error stops the run and raises. Files written earlier in the same run stay in place, and the rest keep their old versions.

Because each file is replaced in one rename, a reader such as a DNS server or the Rails concern above never sees a partial file.

## Reference

### `AiAgentBlocklist::Client`

| Method | Returns | Notes |
|---|---|---|
| `new(token = nil, base_url:, timeout:, user_agent:, transport:)` | client | token falls back to `ENV["AIAGENTBLOCKLIST_TOKEN"]`; `timeout` in seconds, default 30 |
| `#file_list_url` | `String` | the HTML page that lists your files |
| `#file_url(name)` | `String` | full URL; raises `Error` on a bad name |
| `#download(name)` | `String` (binary) | one file body |
| `#download_to(name, path)` | `true` / `false` | conditional GET, `.etag` sidecar, atomic rename |
| `#sync(dir, names = FILES)` | `Hash{String => Boolean}` | `download_to` for each file |
| `#load_blocklist` | `Blocklist` | downloads and parses `aab_full.json` |
| `.bare_etag(etag)` | `String` | strips `W/`, quotes and `-gzip` |
| `FILES` | `Array<String>` | all 19 published names |

### `AiAgentBlocklist::Blocklist`

| Method | Returns | Notes |
|---|---|---|
| `.from_file(path)` / `.from_json(text)` | `Blocklist` | raises `Error` on unreadable or invalid input |
| `#version`, `#product`, `#counts`, `#entries` | metadata and rows | `Enumerable` over entries |
| `#check_domain(host_or_url)` | `Entry` or `nil` | host plus parent domains, kind `domain` only |
| `#check_extension(id)` | `Entry` or `nil` | add-on IDs for browsers plus plugin IDs for editors and IDEs |
| `#check_process(name)` | `Entry` or `nil` | `name.exe` and `name` are the same |
| `#check_package(:npm / :pypi, name)` | `Entry` or `nil` | PyPI names are normalised |
| `#check(identifier)` | `Entry` or `nil` | domain first, then any exact identifier |
| `#filter(agent_type:, kind:, risk_grade:)` | `Array<Entry>` | all keywords optional, case-insensitive |
| `#domains`, `#agent_types`, `#kinds` | `Array<String>` | sorted, distinct |

`AiAgentBlocklist::Entry` is a keyword `Struct`. The members you will use most are `ident`, `kind`, `agent_type` and `risk_grade`; the rest are `tool_name`, `tool_domain`, `name`, `platform`, `category` and `subcategory`. It also has `#to_h`, `#to_json` and `#domain?`.

## Rescuing errors

Every exception is an `AiAgentBlocklist::Error`, so one `rescue` covers the gem. Subclasses let you treat the cases that need a human differently from the ones that will fix themselves.

| Class | Raised when | `#status` |
|---|---|---|
| `TokenError` | token missing or not 32 letters and digits (before any request) | `nil` |
| `NotFoundError` | the token or the file name is unknown | `404` |
| `AccessEndedError` | the subscription has ended or is paused | `403` |
| `HttpError` | any other non-2xx status | the status |
| `Error` | invalid file name, network failure, broken JSON | `nil` |

```ruby
begin
  client.sync(dir)
rescue AiAgentBlocklist::TokenError, AiAgentBlocklist::NotFoundError
  AdminMailer.aab_token_problem.deliver_later
rescue AiAgentBlocklist::AccessEndedError
  AdminMailer.aab_renewal_needed.deliver_later
rescue AiAgentBlocklist::Error => e
  Rails.logger.warn("aab sync will retry: #{e.message}")
end
```

Error messages never include the token, and `Client#inspect` hides it too, so neither shows up in exception trackers.

## Matching rules, briefly

- **Domains.** Input can be a bare host or a whole URL. The gem lowercases it, removes scheme, credentials, port, path, query and fragment, drops a trailing dot, and then tries the host and each parent. `cdn.example-agent.ai` hits a listed `example-agent.ai`; `notexample-agent.ai` does not.
- **Extensions.** Exact match without regard to case.
- **Processes.** Case-insensitive, and a trailing `.exe` is ignored on both sides.
- **Packages.** npm names are lowercased and compared exactly. PyPI names use the [PEP 503](https://peps.python.org/pep-0503/) rule, so dots, dashes and underscores are interchangeable.
- **`check`.** Tries the domain rules first and then an exact identifier match across every kind.

## Feed files you will reach for

Each file sits at `https://www.aiagentblocklist.com/download/<TOKEN>/<file>` and keeps the same name every day.

| File | Contents | Where Ruby teams use it |
|---|---|---|
| `aab_full.json` | every entry plus counts | `Blocklist.from_file` |
| `aab_full.csv` | the same rows as CSV | `CSV.foreach` into a reporting table |
| `domains.txt` | one domain per line | resolvers, allow and deny lists in your own code |
| `dns_rpz.zone` | response policy zone | DNS servers that support [RPZ](https://en.wikipedia.org/wiki/Response_policy_zone) |
| `firewall_edl.txt` | one host per line | firewall external dynamic lists |
| `firefox_extension_ids.txt` | Firefox add-on IDs | browser policy templates |
| `macos_bundle_ids.txt` | macOS bundle IDs | MDM restriction profiles |
| `npm_packages.txt`, `pypi_packages.txt` | package names | CI checks and private registry rules |
| `counts.json` | totals per kind, agent type and grade | a dashboard widget |

For resolvers, our [DNS blocking guide](https://www.aiagentblocklist.com/network/dns-block-ai.php) walks through the zone file and the plain domain list.

## Production notes for Rails

- **Puma with `preload_app!`.** Load the blocklist lazily inside workers, as the concern does, rather than in an initializer. Then each worker reloads on its own when the file changes.
- **Containers.** Keep the feed out of the image. Mount a volume at `storage/aab`, run the sync as a scheduled job or sidecar container, and let app containers read the same folder.
- **Kubernetes.** A CronJob that runs `bin/rails aab:sync` against a shared volume works well. Give it the token through a Secret mapped to `AIAGENTBLOCKLIST_TOKEN`.
- **Ephemeral disks.** On platforms where the file system resets on deploy, call `client.load_blocklist` at boot and keep the result in memory, then refresh it from a scheduled job.
- **Several app servers.** Sync once per host, or sync on one machine and copy the folder. The ETag sidecars travel with the files, so the next conditional request still works.
- **Proxies.** `Net::HTTP` reads `https_proxy` from the environment, so outbound rules that require a proxy need no code change.

## Testing code that uses the gem

Pass a `transport:` lambda and the client never opens a socket:

```ruby
fake = ->(_method, _uri, _headers, _timeout) { [200, { "etag" => '"t1"' }, File.read("test/fixtures/aab_full.json")] }
client = AiAgentBlocklist::Client.new("a" * 32, transport: fake)
```

For code that only checks, build a `Blocklist` from a tiny JSON fixture with `from_json`. The gem's own minitest suite works this way; run it with `bundle exec rake test`.

## Questions people ask

### Is this an API I call for each request?

No. The gem downloads files and does all matching locally. Your app keeps working even if our site is unreachable for a while, using the last copy on disk.

### Does it need ActiveSupport or Rails?

No. The gem is plain Ruby. The Rails examples use Rails, but `Client` and `Blocklist` run in any script, Sinatra app or Hanami service.

### Is the blocklist thread-safe once loaded?

Yes for reads. A `Blocklist` is built once and its lookup hashes are frozen, so many Puma threads can call `check_domain` at the same moment.

### How large is the parsed data?

A few megabytes in memory. Load it once per process, not once per request, and reload only when the file changes.

### Should we block everything on the list?

That is a policy choice. Some teams block every agent, while others allow a reviewed few and block the rest. The [allowlist versus blocklist guide](https://www.aiagentblocklist.com/guides/allowlist-vs-blocklist-for-ai-agents.php) weighs both approaches.

### What does the risk grade column mean?

Each entry carries Low, Moderate, Elevated, High, Severe or "Not graded". `filter(risk_grade: "High")` gives you one slice if you want to start with a smaller block set.

### Can two processes sync the same folder at once?

Yes. Each write goes to its own temp file and lands with a rename, so the last writer wins and readers always see a whole file. It is still tidier to run one sync job per folder.

### Does the gem retry on its own?

No. It raises on the first failure and leaves retries to the caller, which fits Sidekiq, Active Job and cron. A sync that fails at night simply runs again an hour later.

### How do we reach you?

Use the [contact form](https://www.aiagentblocklist.com/contact.php) or write to info@alpha-quantum.com. Questions about the gem itself can go to the GitHub repository below.

## Links

- Home page: [aiagentblocklist.com](https://www.aiagentblocklist.com/)
- Source code: [github.com/explainableaixai/aiagentblocklist-ruby](https://github.com/explainableaixai/aiagentblocklist-ruby)
- RubyGems: [rubygems.org/gems/aiagentblocklist](https://rubygems.org/gems/aiagentblocklist)
- AI guidance from [CISA](https://www.cisa.gov/ai)
- Email: info@alpha-quantum.com

## License

Copyright (c) 2026 Alpha Quantum. You may use, change and share the gem under the MIT License in `LICENSE`.

## Related

Looking for more than agents? The [AI tools blocklist](https://www.aitoolsblocklist.com) covers AI tools in general, the [app blocklist for MDM](https://www.appblocklist.com) covers mobile apps, and the [web filtering database](https://www.webfilteringdatabase.com) covers website categories.
