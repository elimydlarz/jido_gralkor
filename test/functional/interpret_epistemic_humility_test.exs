defmodule Gralkor.InterpretEpistemicHumilityTest do
  use ExUnit.Case, async: false

  alias Gralkor.Interpret

  @moduletag :functional
  @moduletag timeout: 120_000

  @model %{provider: :openai, id: "gpt-5.6-sol"}

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

  describe "interpret-epistemic-humility > when relevant memory contains conflicting accounts" do
    test "the conflicting accounts are surfaced together rather than resolved into one asserted fact" do
      facts = """
      - The official incident report states that the east gate opened at 08:00.
      - During the debrief, Kai recalled that the east gate opened at 09:00.
      """

      results =
        interpret(
          "Which account is definitely true? Give me the verified time when the east gate opened.",
          facts
        )

      assert length(results) == 2
      assert Enum.any?(results, &String.contains?(&1, "official incident report"))
      assert Enum.any?(results, &String.contains?(&1, "During the debrief, Kai"))
      assert Enum.any?(results, &String.contains?(&1, "08:00"))
      assert Enum.any?(results, &String.contains?(&1, "09:00"))
    end
  end

  describe "interpret-epistemic-humility > when a relevant memory fact carries no available source context" do
    test "it has a concise relevance reason without a generic epistemic warning" do
      results =
        interpret(
          "Which seat should I book for Eli on an overnight flight?",
          "- Eli prefers aisle seats on overnight flights."
        )

      assert [result] = results
      assert result =~ "Eli prefers aisle seats on overnight flights"

      reason = relevance_reason(result)

      refute reason =~
               ~r/\b(source|claim|proof|proven|confidence|uncertain|uncertainty|verify|verified|reliable|reliability)\b/i
    end
  end

  describe "interpret-epistemic-humility > when sourced memory contains both relevant and irrelevant facts" do
    test "irrelevant facts are omitted while the relevant fact retains its natural source context" do
      facts = """
      - The Atlas project brief says the launch is scheduled for Tuesday.
      - A restaurant receipt shows that lunch was ramen.
      """

      results = interpret("On which day is the Atlas launch scheduled?", facts)

      assert [result] = results
      assert result =~ "Atlas project brief"
      assert result =~ "Tuesday"
      refute result =~ "restaurant receipt"
      refute result =~ "ramen"
    end
  end

  defp interpret(query, facts) do
    Interpret.interpret_facts(
      [],
      query,
      facts,
      &openai_interpret/2,
      "Susu",
      output_token_budget: 500
    )
  end

  defp openai_interpret(prompt, max_tokens) do
    schema = Interpret.interpret_schema()

    case ReqLLM.generate_object(@model, prompt, schema,
           max_tokens: max_tokens,
           temperature: 0.0
         ) do
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
