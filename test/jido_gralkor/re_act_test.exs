defmodule JidoGralkor.ReActTest do
  use ExUnit.Case, async: true

  alias JidoGralkor.ReAct

  defp state(iteration), do: %{iteration: iteration}

  describe "when request-transformer overrides are folded on the first ReAct iteration > while the overrides already carry llm options" do
    test "then a tool choice pinning the memory search function is folded into those llm options" do
      result = ReAct.maybe_force_memory_search(%{llm_opts: [other: :preserved]}, state(1))

      assert result[:llm_opts][:tool_choice] == %{
               type: "function",
               function: %{name: "memory_search"}
             }
    end

    test "and the llm options the consumer already set survive alongside it" do
      result = ReAct.maybe_force_memory_search(%{llm_opts: [other: :preserved]}, state(1))
      assert result[:llm_opts][:other] == :preserved
    end

    test "and the other override keys are returned unchanged" do
      result =
        ReAct.maybe_force_memory_search(
          %{messages: [:message], llm_opts: [other: :preserved]},
          state(1)
        )

      assert result.messages == [:message]
    end
  end

  describe "when request-transformer overrides are folded on the first ReAct iteration > while the overrides carry no llm options" do
    test "then llm options are added holding only the tool choice pinning the memory search function" do
      assert ReAct.maybe_force_memory_search(%{}, state(1)) == %{
               llm_opts: [
                 tool_choice: %{type: "function", function: %{name: "memory_search"}}
               ]
             }
    end
  end

  describe "when request-transformer overrides are folded on any later ReAct iteration" do
    test "then the overrides are returned unchanged, leaving the model free to answer or call other tools" do
      overrides = %{messages: [:message], llm_opts: [other: :preserved]}
      assert ReAct.maybe_force_memory_search(overrides, state(2)) == overrides
      assert ReAct.maybe_force_memory_search(overrides, state(5)) == overrides
    end
  end
end
