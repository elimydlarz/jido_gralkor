defmodule JidoGralkor.Actions.ErrorEncoderCompatTest do
  @moduledoc """
  Wire compatibility samples for action errors that must survive
  `Jido.AI.Signal.Helpers.normalize_error/4` → `Jason.encode!/1` without crashing
  the AgentServer.

  In jido_ai 2.1.0 `normalize_error`'s `%{message: …}` clause did `Map.drop`
  on the struct reason, which preserves `__struct__`; `Jason.encode!` then
  raised `Protocol.UndefinedError`, killing the AgentServer. Fixed upstream
  on `main` (refactor commit `d60699c0`, 2026-05-21) by reordering clauses
  and routing `Jido.Action.Error.*` through `Jido.Error.to_map/1`. Until the
  fix is published and pinned (last release: v2.1.0), this test pins our
  side of the contract through five explicit representative fixtures. This is
  not an exhaustive algebra of every term a configured client may return.
  Plan to simplify or delete once jido_ai > 2.1.0 ships and we bump.
  """

  use ExUnit.Case, async: true

  alias Jido.AI.Signal.Helpers, as: SignalHelpers

  # Explicit compatibility fixtures, not an exhaustive list of every term a
  # configured client can return.
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

  describe "when an action error is normalised into a tool-error envelope" do
    test "then the envelope encodes to JSON without raising" do
      for reason <- @reasons do
        envelope = normalise(reason)
        assert is_binary(Jason.encode!(%{ok: false, error: envelope}))
      end
    end

    test "and its details hold no struct" do
      for reason <- @reasons do
        refute is_struct(normalise(reason)[:details])
      end
    end

    test "and all five explicitly listed compatibility fixtures normalise to maps" do
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
