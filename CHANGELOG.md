# Changelog

All notable changes to the `aiagentblocklist` gem are recorded here. The project follows Semantic Versioning.

## 1.0.0

First release.

- `AiAgentBlocklist::Client.new(token = nil, base_url:, timeout:, user_agent:, transport:)`; the token falls back to `ENV["AIAGENTBLOCKLIST_TOKEN"]` and is checked before any request.
- `#file_url`, `#file_list_url`, `#download`, `#download_to` (ETag sidecar, If-None-Match, atomic rename), `#sync` and `#load_blocklist`.
- `AiAgentBlocklist::Blocklist.from_json` / `.from_file` with `#check_domain`, `#check_extension`, `#check_process`, `#check_package`, `#check`, `#filter`, `#domains`, `#agent_types` and `#kinds`. Enumerable over entries; lookup hashes are built once.
- `AiAgentBlocklist::Entry` struct with the ten feed columns.
- Errors: `AiAgentBlocklist::Error` (with `#status`), `NotFoundError`, `AccessEndedError`, `HttpError`, `TokenError`. Network failures are wrapped in `Error`.
- Standard library only (`net/http`, `json`). Offline minitest suite.
