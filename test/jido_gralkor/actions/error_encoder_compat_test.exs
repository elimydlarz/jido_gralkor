defmodule JidoGralkor.Actions.ErrorEncoderCompatTest do
  @moduledoc """
  Wire contract: every `{:error, reason}` our actions are allowed to return must
  survive `Jido.AI.Signal.Helpers.normalize_error/4` → `Jason.encode!/1` without
  crashing the AgentServer.

  In jido_ai 2.1.0 `normalize_error`'s `%{message: …}` clause did `Map.drop`
  on the struct reason, which preserves `__struct__`; `Jason.encode!` then
  raised `Protocol.UndefinedError`, killing the AgentServer. Fixed upstream
  on `main` (refactor commit `d60699c0`, 2026-05-21) by reordering clauses
  and routing `Jido.Action.Error.*` through `Jido.Error.to_map/1`. Until the
  fix is published and pinned (last release: v2.1.0), this test pins our
  side of the contract — every `{:error, reason}` shape any of our actions
  can produce must encode cleanly. Plan to simplify or delete once jido_ai
  > 2.1.0 ships and we bump.
  """

  use ExUnit.Case, async: true

  alias Jido.AI.Signal.Helpers, as: SignalHelpers

  # Every error reason any of `JidoGralkor.Actions.*` can produce today.
  # If you add a new error path, append it here.
  @reasons [
    # Gralkor.Recall.recall/5
    :recall_deadline_expired,
    # Gralkor.GraphitiPool.{search,add_episode,build_indices,build_communities}
    {:python,
     "Python exception raised\n\n  Traceback (most recent call last):\n    File \"<string>\", line 2, in <module>\n  RuntimeError: boom\n"},
    # Gralkor.CaptureBuffer.flush_and_await/2
    :timeout,
    # InMemory test twin scenarios
    :boom,
    # Defensive: a bare binary reason (some adapters may return strings)
    "Gralkor server unreachable"
  ]

  describe "when any error reason our actions can return is normalised into a tool-error envelope" do
    test "then the envelope encodes to JSON without raising, so the agent server survives the failure" do
      for reason <- @reasons do
        envelope = normalise(reason)
        assert is_binary(Jason.encode!(%{ok: false, error: envelope}))
      end
    end

    test "and the envelope's details never hold a struct, which JSON encoding cannot serialise" do
      for reason <- @reasons do
        refute is_struct(normalise(reason)[:details])
      end
    end

    test "and the guarantee holds for every reason shape our actions produce, including recall deadlines, Python exception tuples, timeouts, bare atoms, and plain strings" do
      assert Enum.count(@reasons) == 5
      assert Enum.all?(@reasons, &(normalise(&1) |> is_map()))
    end
  end

  defp normalise(reason) do
    SignalHelpers.normalize_error(reason, :execution_error, "Tool execution failed", %{
      tool_name: "memory_search"
    })
  end
end
