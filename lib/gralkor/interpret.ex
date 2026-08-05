defmodule Gralkor.Interpret do
  @moduledoc """
  Filter retrieved graph facts down to those relevant to the conversation,
  using the configured LLM.

  Two responsibilities, each its own tree:

    * `build_interpretation_context/5` — pure: assemble the LLM prompt from
      conversation messages, the request being answered, and a formatted facts
      string, dropping oldest messages until the prompt fits the configured
      char budget. Renders role labels using `agent_name`.
    * `interpret_facts/6` — call the LLM with that prompt and a structured-
      output schema; return the list of relevant facts the LLM selected.

  The request travels separately from the conversation because a recall may be
  made from a session that never carried it — a fresh session, or a memory
  search whose query is not the last thing the user said. Without it the model
  has nothing to judge relevance against.

  See `test-trees/unit/interpret_TEST_TREES.md`.
  """

  alias Gralkor.InterpretParseFailed
  alias Gralkor.Message

  @default_budget 8_000
  @default_output_token_budget 2_000

  @type interpret_fn ::
          (String.t(), pos_integer() ->
             {:ok, [String.t()]} | {:error, term()})

  @doc """
  Run the LLM over the conversation context + facts text, returning the
  filtered list of relevant facts.

  `opts[:output_token_budget]` (default `#{@default_output_token_budget}`) is
  passed to `interpret_fn` so the LLM-side wiring can set `max_tokens` on the
  provider call, and is also rendered into the prompt as a self-limit
  instruction.

  Raises `Gralkor.InterpretParseFailed` if the LLM returns a response that
  can't be parsed against the schema (truncation, schema mismatch). Raises
  `RuntimeError` if the call returns `{:error, _}` (upstream LLM failure).
  Raises `ArgumentError` if `agent_name` is blank or the output token budget
  is non-positive/non-integer.
  """
  @spec interpret_facts([Message.t()], String.t(), interpret_fn(), String.t(), keyword()) ::
          [String.t()]
  def interpret_facts(messages, facts_text, interpret_fn, agent_name, opts \\ [])
      when is_list(messages) and is_binary(facts_text) and is_function(interpret_fn, 2) do
    raise_if_blank!(agent_name)
    output_token_budget = output_token_budget!(opts)
    prompt = build_interpretation_context(messages, facts_text, agent_name, opts)

    prompt_with_budget =
      Enum.join(
        [prompt, epistemic_instruction(), budget_instruction(output_token_budget)],
        "\n\n"
      )

    case interpret_fn.(prompt_with_budget, output_token_budget) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          list
        else
          raise InterpretParseFailed, raw_response: list
        end

      {:error, reason} ->
        raise "interpret failed: #{inspect(reason)}"

      other ->
        raise InterpretParseFailed, raw_response: other
    end
  end

  @doc """
  Schema for the structured-output response the LLM returns.
  """
  @spec interpret_schema() :: keyword()
  def interpret_schema do
    [
      relevantFacts: [
        type: {:list, :string},
        required: true,
        doc:
          "Each entry is one fact line copied verbatim from the input " <>
            "(preserving every timestamp parenthetical such as '(created …)', " <>
            "'(valid from …)', '(invalid since …)', '(expired …)'; dropping the " <>
            "leading '- '), followed by ' — ' and a one-sentence relevance reason."
      ]
    ]
  end

  @doc """
  Assemble the LLM prompt from conversation messages and the formatted facts.

  Drops oldest messages until the assembled prompt fits the char budget
  (`opts[:budget]`, default #{@default_budget}). Raises on blank agent_name.
  """
  @spec build_interpretation_context([Message.t()], String.t(), String.t(), keyword()) ::
          String.t()
  def build_interpretation_context(messages, facts_text, agent_name, opts \\ [])
      when is_list(messages) and is_binary(facts_text) do
    raise_if_blank!(agent_name)
    budget = Keyword.get(opts, :budget, @default_budget)

    messages
    |> labelled_lines(agent_name)
    |> fit_to_budget(facts_text, budget)
    |> assemble(facts_text)
  end

  # ── internal ────────────────────────────────────────────────

  defp output_token_budget!(opts) do
    value = Keyword.get(opts, :output_token_budget, @default_output_token_budget)

    if is_integer(value) and value > 0 do
      value
    else
      raise ArgumentError,
            "output_token_budget must be a positive integer, got #{inspect(value)}"
    end
  end

  defp budget_instruction(budget) do
    "Respond within #{budget} tokens. Keep each relevance reason short so the full list fits."
  end

  defp epistemic_instruction do
    "Return only facts that directly help answer the user's request. Omit every unrelated fact, " <>
      "even when it appears alongside relevant material. Treat retrieved memory facts as " <>
      "understandings extracted from source material rather " <>
      "than proven claims. Mention the source context, when available, only where natural, " <>
      "without confidence labels, truth adjudication, or repetitive uncertainty warnings. " <>
      "When retrieved memory facts conflict, preserve the relevant accounts rather than " <>
      "choosing one as true."
  end

  defp raise_if_blank!(name) when is_binary(name) do
    if String.trim(name) == "" do
      raise ArgumentError, "agent_name must be a non-blank string, got #{inspect(name)}"
    end

    :ok
  end

  defp raise_if_blank!(other) do
    raise ArgumentError, "agent_name must be a non-blank string, got #{inspect(other)}"
  end

  defp labelled_lines(messages, agent_name) do
    messages
    |> Enum.map(fn m -> {m.role, String.trim(m.content)} end)
    |> Enum.reject(fn {_, c} -> c == "" end)
    |> Enum.map(fn {role, content} -> render_line(role, content, agent_name) end)
  end

  defp render_line("user", content, _agent), do: "User: #{content}"
  defp render_line("assistant", content, agent), do: "#{agent}: #{content}"
  defp render_line("behaviour", content, agent), do: "#{agent}: (behaviour: #{content})"

  defp fit_to_budget([], _facts, _budget), do: []

  defp fit_to_budget(lines, facts, budget) do
    if String.length(assemble(lines, facts)) <= budget do
      lines
    else
      [_oldest | rest] = lines
      fit_to_budget(rest, facts, budget)
    end
  end

  defp assemble(lines, facts_text) do
    "Conversation context:\n" <>
      Enum.join(lines, "\n") <>
      "\n\nMemory facts to interpret:\n" <>
      facts_text
  end
end
