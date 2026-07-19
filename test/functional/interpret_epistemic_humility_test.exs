defmodule Gralkor.InterpretEpistemicHumilityTest do
  use ExUnit.Case, async: false

  alias Gralkor.Interpret
  alias Gralkor.Message

  @moduletag :functional
  @moduletag timeout: 120_000

  @model %{provider: :openai, id: "gpt-5-nano"}

  setup_all do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and byte_size(key) > 0 -> :ok
      _ -> raise "OPENAI_API_KEY must be set in .env for this functional suite"
    end
  end

  describe "interpret-epistemic-humility > when relevant memory contains accounts from sources with different apparent veracity" do
    test "every needed account retains its source wording without reliability ranking or truth adjudication" do
      facts = """
      - A signed harbour log records strong northerly wind during the inspection.
      - In an interview, Noor remembered unusually high waves during the inspection.
      - An anonymous message-board post claimed the pier lights flickered during the inspection.
      """

      results =
        interpret(
          "List every available account of conditions during the inspection, including its source.",
          facts
        )

      assert length(results) == 3
      assert Enum.any?(results, &String.contains?(&1, "signed harbour log"))
      assert Enum.any?(results, &String.contains?(&1, "In an interview, Noor"))
      assert Enum.any?(results, &String.contains?(&1, "anonymous message-board post"))

      reasons = results |> Enum.map(&relevance_reason/1) |> Enum.join(" ")

      refute reasons =~
               ~r/\b(more reliable|less reliable|reliable|unreliable|verified|unverified|proven|true|false)\b/i
    end
  end

  defp interpret(query, facts) do
    Interpret.interpret_facts(
      [Message.new("user", query)],
      facts,
      &openai_interpret/2,
      "Susu",
      output_token_budget: 500
    )
  end

  defp openai_interpret(prompt, max_tokens) do
    schema = Interpret.interpret_schema()

    case ReqLLM.generate_object(@model, prompt, schema, max_tokens: max_tokens) do
      {:ok, response} ->
        object = ReqLLM.Response.object(response)
        {:ok, Map.get(object, :relevantFacts) || Map.get(object, "relevantFacts") || []}

      {:error, _} = error ->
        error
    end
  end

  defp relevance_reason(result) do
    case String.split(result, " — ", parts: 2) do
      [_fact, reason] -> reason
      _ -> ""
    end
  end
end
