defmodule JidoGralkor.ContextRotatorTest do
  use ExUnit.Case, async: true

  alias JidoGralkor.ContextRotator

  defp entry(seq, content),
    do: %{kind: :ai_message, seq: seq, payload: %{role: :user, content: content}}

  describe "when a rotation seed is computed > while every current entry was in the flushed set" do
    test "then the seed is the most recent entries up to the retention count" do
      pre = [entry(0, "a"), entry(1, "b"), entry(2, "c"), entry(3, "d")]

      assert ContextRotator.compute_seed(pre, pre, 2) == [entry(2, "c"), entry(3, "d")]
    end
  end

  describe "when a rotation seed is computed > while every current entry was in the flushed set > while the retention count is zero" do
    test "then the seed is empty rather than falling back to any default retention" do
      pre = [entry(0, "a"), entry(1, "b")]

      assert ContextRotator.compute_seed(pre, pre, 0) == []
    end
  end

  describe "when a rotation seed is computed > while the current entries include in-flight entries that arrived after the flushed ones" do
    test "then those in-flight entries are seeded whatever the retention count is, so nothing mid-turn is lost" do
      pre = [entry(0, "a"), entry(1, "b")]
      current = pre ++ [entry(2, "in-flight-1"), entry(3, "in-flight-2")]

      assert ContextRotator.compute_seed(pre, current, 0) ==
               [entry(2, "in-flight-1"), entry(3, "in-flight-2")]
    end

    test "and the retained entries precede the in-flight entries in the seed" do
      pre = [entry(0, "a"), entry(1, "b"), entry(2, "c")]
      current = pre ++ [entry(3, "inflight")]

      assert ContextRotator.compute_seed(pre, current, 1) ==
               [entry(2, "c"), entry(3, "inflight")]
    end
  end

  describe "when a rotation seed is computed > while the current entries include in-flight entries that arrived after the flushed ones > while there were no flushed entries at all" do
    test "then the seed is exactly the in-flight entries" do
      current = [entry(0, "inflight-only")]

      assert ContextRotator.compute_seed([], current, 4) == [entry(0, "inflight-only")]
    end
  end

  describe "when a rotation seed is computed > while every current entry was in the flushed set > while the retention count exceeds the number of flushed entries" do
    test "then every flushed entry is seeded" do
      pre = [entry(0, "a")]
      current = pre

      assert ContextRotator.compute_seed(pre, current, 10) == pre
    end

    test "and no more are invented" do
      pre = [entry(0, "a")]

      assert length(ContextRotator.compute_seed(pre, pre, 10)) == length(pre)
    end
  end
end
