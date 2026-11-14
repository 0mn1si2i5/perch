# dsh Web protocol fixtures

These synthetic payloads are consumed by the macOS and Windows test suites. They contain no real accounts, authorization tokens, API keys or conversation bodies.

- `sessions.json`: only root conversations survive filtering; idle, unavailable and unknown states must not become successful completion. Working directories are opaque metadata, including spaces and platform-specific separators.
- `outcomes.json`: completion requires an explicit completed `turn/end`; a later `turn/start` supersedes it. `null` means that the event window proves no outcome.
- `wallet.json`: preserve currency, paid/granted components and decimal precision. Never combine different billing sources or currencies into a percentage.

Platform adapters may use different localized labels, but must preserve these states and values. HTTP transport, credential storage and process ownership remain native to each platform.
