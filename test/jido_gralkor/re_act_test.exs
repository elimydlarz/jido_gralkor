defmodule JidoGralkor.ReActTest do
  use ExUnit.Case, async: true

  alias JidoGralkor.ReAct

  defp state(iter), do: %{iteration: iter}

  describe "when state.iteration == 1 (first ReAct turn)" do
    test "the returned overrides carry llm_opts: [tool_choice: %{type: \"function\", function: %{name: \"memory_search\"}}], folded into existing :llm_opts" do
      overrides = %{messages: [:msg], llm_opts: [other: :preserved]}

      out = ReAct.maybe_force_memory_search(overrides, state(1))

      assert out.messages == [:msg]
      assert Keyword.get(out.llm_opts, :tool_choice) == %{type: "function", function: %{name: "memory_search"}}
      assert Keyword.get(out.llm_opts, :other) == :preserved
    end
  end

  describe "when state.iteration > 1" do
    test "the overrides are returned unchanged" do
      overrides = %{messages: [:msg], llm_opts: [other: :preserved]}

      assert ReAct.maybe_force_memory_search(overrides, state(2)) == overrides
      assert ReAct.maybe_force_memory_search(overrides, state(5)) == overrides
    end
  end

  describe "when overrides has no :llm_opts key on iteration 1" do
    test "then :llm_opts is added with [tool_choice: {:tool, \"memory_search\"}]" do
      out = ReAct.maybe_force_memory_search(%{}, state(1))

      assert out.llm_opts == [tool_choice: %{type: "function", function: %{name: "memory_search"}}]
    end
  end
end
