# Changelog

## [2.0.1] - 2026-05-21

### Changed
- `:gralkor_ex` pin bumped to `~> 3.1` to pick up `Gralkor.InterpretParseFailed` and the `:interpret_max_output_tokens` app env knob. Operators can now set `:gralkor_ex, :interpret_max_output_tokens` directly to control the interpret pipeline's output budget; see `Configuring Gralkor` in this package's README for the documentation.

## [2.0.0] - 2026-05-18

### Changed
- **BREAKING.** `:gralkor_ex` pin bumped to `~> 3.0`. The upstream renamed `end_session/1` to `flush/1` and added `flush_and_await/2`; consumers building against `:gralkor_ex ~> 2.x` no longer compile against this version.
- **BREAKING.** `JidoGralkor.Lifecycle` no longer owns idle-timer machinery. Its sole responsibility is now the death-triggered flush: on `AgentServer` graceful termination it fires `Gralkor.Client.flush/1` for the active session and returns. Consumers that want idle timeouts should use Jido's built-in `AgentServer` `:idle_timeout` option directly.

### Added
- `JidoGralkor.ContextRotator` — synchronous `rotate_now/2` primitive for in-life context consolidation. Flushes the active Gralkor session via `Gralkor.Client.flush_and_await/2`, installs a fresh thread on the agent, and seeds the rotated thread with the most-recent `keep_last_n` pre-flush entries plus any in-flight turns appended during the flush. The agent process is never stopped; periodic rotation is left to the consumer.
