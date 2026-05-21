defmodule JidoGralkor.ContextRotatorTest do
  use ExUnit.Case, async: true

  alias JidoGralkor.ContextRotator

  defp entry(seq, content),
    do: %{kind: :ai_message, seq: seq, payload: %{role: :user, content: content}}

  describe "compute_seed/3" do
    test "with no in-flight entries, returns the last keep_last_n pre-flush entries" do
      pre = [entry(0, "a"), entry(1, "b"), entry(2, "c"), entry(3, "d")]

      assert ContextRotator.compute_seed(pre, pre, 2) == [entry(2, "c"), entry(3, "d")]
    end

    test "with keep_last_n: 0 and no in-flight entries, returns []" do
      pre = [entry(0, "a"), entry(1, "b")]

      assert ContextRotator.compute_seed(pre, pre, 0) == []
    end

    test "with in-flight entries (seq beyond max pre-flush seq), preserves them regardless of keep_last_n" do
      pre = [entry(0, "a"), entry(1, "b")]
      current = pre ++ [entry(2, "in-flight-1"), entry(3, "in-flight-2")]

      assert ContextRotator.compute_seed(pre, current, 0) ==
               [entry(2, "in-flight-1"), entry(3, "in-flight-2")]
    end

    test "keep_last_n entries come BEFORE in-flight entries in the seed" do
      pre = [entry(0, "a"), entry(1, "b"), entry(2, "c")]
      current = pre ++ [entry(3, "inflight")]

      assert ContextRotator.compute_seed(pre, current, 1) ==
               [entry(2, "c"), entry(3, "inflight")]
    end

    test "with empty pre-flush entries, returns just the in-flight entries" do
      current = [entry(0, "inflight-only")]

      assert ContextRotator.compute_seed([], current, 4) == [entry(0, "inflight-only")]
    end

    test "with keep_last_n > pre-flush length, returns all pre-flush entries (plus any in-flight)" do
      pre = [entry(0, "a")]
      current = pre

      assert ContextRotator.compute_seed(pre, current, 10) == pre
    end
  end
end
