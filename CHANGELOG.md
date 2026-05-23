# Changelog

## [Unreleased]

### Changed
- **BREAKING.** Application-env namespace unified under `:jido_gralkor`. The legacy `:gralkor_ex` atom (preserved at 3.0.0 for zero-churn migration) is gone — consumers must rewrite every `config :gralkor_ex, …` line and every `Application.{get,put,delete}_env(:gralkor_ex, …)` call to `:jido_gralkor`. This removes the cosmetic `application :gralkor_ex ... is not available` warning Mix printed at boot because no `:gralkor_ex` OTP application ships.

## [3.0.0] - 2026-05-21

### Changed
- **BREAKING.** Absorbed the former `:gralkor_ex` Hex package. The `Gralkor.*` module namespace (Client, Client.Native, Client.InMemory, Python, GraphitiPool, CaptureBuffer, Recall, Distill, Interpret, Format, Config, Application) is now shipped inside `:jido_gralkor` itself — consumers no longer need a separate `{:gralkor_ex, ...}` line in `mix.exs`. Drop it; keep only `{:jido_gralkor, "~> 3.0"}`. The legacy `:gralkor_ex` package is deprecated on Hex and points here.
- The OTP `mod:` is now `Gralkor.Application`, supervising `Gralkor.Python` → `GraphitiPool` → `CaptureBuffer` when a FalkorDB backend is configured (embedded via `GRALKOR_DATA_DIR` or remote via `config :gralkor_ex, :falkordb`); empty children otherwise.

### Preserved (zero-churn for existing consumers)
- The `:gralkor_ex` Application-env namespace is preserved. Existing `config :gralkor_ex, falkordb: [...]` / `config :gralkor_ex, :interpret_max_output_tokens` / `config :gralkor_ex, client: Gralkor.Client.InMemory` lines in consumer configs continue to work unchanged — the atom is a stable namespace key the embedded code still reads.
- Public API surface (`JidoGralkor.Plugin`, `JidoGralkor.ReAct`, `JidoGralkor.Lifecycle`, `JidoGralkor.ContextRotator`, `JidoGralkor.Canonical`, `JidoGralkor.Actions.*`) and module shapes are unchanged. The merge is purely a packaging consolidation.

## [2.0.1] - 2026-05-21

### Changed
- `:gralkor_ex` pin bumped to `~> 3.1` to pick up `Gralkor.InterpretParseFailed` and the `:interpret_max_output_tokens` app env knob. Operators can now set `:gralkor_ex, :interpret_max_output_tokens` directly to control the interpret pipeline's output budget; see `Configuring Gralkor` in this package's README for the documentation.

## [2.0.0] - 2026-05-18

### Changed
- **BREAKING.** `:gralkor_ex` pin bumped to `~> 3.0`. The upstream renamed `end_session/1` to `flush/1` and added `flush_and_await/2`; consumers building against `:gralkor_ex ~> 2.x` no longer compile against this version.
- **BREAKING.** `JidoGralkor.Lifecycle` no longer owns idle-timer machinery. Its sole responsibility is now the death-triggered flush: on `AgentServer` graceful termination it fires `Gralkor.Client.flush/1` for the active session and returns. Consumers that want idle timeouts should use Jido's built-in `AgentServer` `:idle_timeout` option directly.

### Added
- `JidoGralkor.ContextRotator` — synchronous `rotate_now/2` primitive for in-life context consolidation. Flushes the active Gralkor session via `Gralkor.Client.flush_and_await/2`, installs a fresh thread on the agent, and seeds the rotated thread with the most-recent `keep_last_n` pre-flush entries plus any in-flight turns appended during the flush. The agent process is never stopped; periodic rotation is left to the consumer.
