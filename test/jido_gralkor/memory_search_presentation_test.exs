defmodule JidoGralkor.MemorySearchPresentationTest do
  use ExUnit.Case, async: true

  alias JidoGralkor.MemorySearchPresentation, as: Presentation

  describe "when memory results are selected for a model byte budget" do
    test "then an exact-fit complete success envelope retains the unchanged result" do
      result = %{
        destination: "global",
        episode: %{artefact: %{id: "a", payload: %{history: [%{content: "complete"}]}}}
      }

      expected = %{result: [result], omissions: %{byte_budget: 0}}
      assert Presentation.for_model([result], envelope_bytes(expected)) == {:ok, expected}
    end

    test "and UTF-8 bytes and JSON escaping count towards the budget" do
      result = %{destination: "operator", episode: %{content: "λ\n\"\\"}}
      expected = %{result: [result], omissions: %{byte_budget: 0}}
      bytes = envelope_bytes(expected)
      assert Presentation.for_model([result], bytes) == {:ok, expected}

      assert Presentation.for_model([result], bytes - 1) ==
               {:ok, %{result: [], omissions: %{byte_budget: 1}}}
    end

    test "and an oversized result is omitted whole while later fitting results retain their order" do
      first = %{destination: "a", episode: %{content: "first"}}

      oversized = %{
        destination: "b",
        episode: %{artefact: %{id: "b", payload: %{history: [String.duplicate("full", 1000)]}}}
      }

      last = %{destination: "c", episode: %{content: "last"}}
      expected = %{result: [first, last], omissions: %{byte_budget: 1}}

      assert Presentation.for_model([first, oversized, last], envelope_bytes(expected)) ==
               {:ok, expected}
    end

    test "and omission metadata counts every excluded result outside the result list" do
      results =
        Enum.map(
          1..101,
          &%{destination: "global", episode: %{content: String.duplicate("x", 1000), id: &1}}
        )

      expected = %{result: [], omissions: %{byte_budget: 101}}
      assert Presentation.for_model(results, envelope_bytes(expected)) == {:ok, expected}
    end
  end

  describe "when memory results are selected for a model byte budget > while the result list is empty" do
    test "then the minimum budget returns an empty result list with zero omissions" do
      expected = %{result: [], omissions: %{byte_budget: 0}}
      assert Presentation.for_model([], envelope_bytes(expected)) == {:ok, expected}
    end
  end

  describe "when memory results are selected for a model byte budget > while the budget cannot contain the empty envelope and its omission count" do
    test "then an explicit error reports the required minimum bytes" do
      results = List.duplicate(%{destination: "global"}, 100)
      minimum = envelope_bytes(%{result: [], omissions: %{byte_budget: 100}})

      assert Presentation.for_model(results, minimum - 1) ==
               {:error,
                {:memory_search_budget_too_small,
                 %{max_bytes: minimum - 1, minimum_bytes: minimum}}}
    end
  end

  describe "when memory results are selected for a model byte budget > if the budget is not a positive integer" do
    test "then an argument error identifies the invalid budget" do
      for invalid <- [0, -1, nil, "100", 1.5] do
        assert_raise ArgumentError,
                     "memory_search_max_bytes must be a positive integer, got: #{inspect(invalid)}",
                     fn ->
                       Presentation.for_model([], invalid)
                     end
      end
    end
  end

  describe "when the action validates a model byte budget before search" do
    test "then a positive integer is returned unchanged" do
      assert Presentation.validate_max_bytes!(1) == 1
      assert Presentation.validate_max_bytes!(65_536) == 65_536
    end
  end

  describe "when the action validates a model byte budget before search > if the budget is not a positive integer" do
    test "then an argument error identifies the invalid budget" do
      for invalid <- [0, -1, nil, "100", 1.5] do
        assert_raise ArgumentError,
                     "memory_search_max_bytes must be a positive integer, got: #{inspect(invalid)}",
                     fn ->
                       Presentation.validate_max_bytes!(invalid)
                     end
      end
    end
  end

  defp envelope_bytes(output), do: byte_size(Jason.encode!(%{ok: true, result: output}))
end
