defmodule Gralkor.Learn do
  @moduledoc """
  Turn one ERL-marked reasoning turn into a single flat `Gralkor.AgentLearning`
  record via one LLM call.

  Same shape as `Gralkor.Distill` — best-effort and parallel-friendly. The turn
  is rendered with role labels and handed to the injected `learn_fn` (a
  structured-output LLM caller); production wiring lives in
  `Gralkor.Client.Native`. Classification and learning are one step: the record
  is a single node carrying the problem kind, the approach, whether it
  succeeded, and the lesson.

  See `ex-learn` in `TEST_TREES.md`.
  """

  alias Gralkor.AgentLearning
  alias Gralkor.Message

  @type turn :: [Message.t()]
  @type learn_fn :: (String.t() -> {:ok, map()} | {:error, term()})

  @doc """
  Run the LLM over `turn`, returning the learning record it produced.

  Returns `{:error, reason}` (best-effort) when `learn_fn` fails — the caller
  writes no learning episode for that turn. Raises `ArgumentError` when
  `agent_name` or `user_name` is blank.
  """
  @spec learn(turn(), learn_fn(), String.t(), String.t()) ::
          {:ok, AgentLearning.t()} | {:error, term()}
  def learn(turn, learn_fn, agent_name, user_name)
      when is_list(turn) and is_function(learn_fn, 1) do
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    case learn_fn.(prompt(turn, agent_name, user_name)) do
      {:ok, record} when is_map(record) ->
        {:ok, build(record)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Schema for the structured-output response the LLM returns when learning from a
  turn.
  """
  @spec learn_schema() :: keyword()
  def learn_schema do
    [
      problem_kind: [
        type: :string,
        required: true,
        doc: "The kind of problem that was being approached this turn (a short, reusable category)."
      ],
      approach: [
        type: :string,
        required: true,
        doc: "The approach the agent took to the problem."
      ],
      success: [
        type: :boolean,
        required: true,
        doc: "Whether the approach succeeded in solving the problem."
      ],
      lesson: [
        type: :string,
        required: true,
        doc: "What did you learn that enabled you to solve this problem?"
      ]
    ]
  end

  # ── internal ────────────────────────────────────────────────

  defp build(record) do
    %AgentLearning{
      problem_kind: fetch(record, :problem_kind),
      approach: fetch(record, :approach),
      success: !!fetch(record, :success),
      lesson: fetch(record, :lesson)
    }
  end

  defp fetch(record, key) do
    Map.get(record, key) || Map.get(record, Atom.to_string(key))
  end

  defp prompt(turn, agent_name, user_name) do
    """
    Review the following reasoning turn and report what you learned that enabled
    you to solve (or attempt) the problem.

    #{render(turn, agent_name, user_name)}
    """
  end

  defp render(turn, agent_name, user_name) do
    turn
    |> Enum.map(fn m ->
      case m.role do
        "user" -> "#{user_name}: #{m.content}"
        "assistant" -> "#{agent_name}: #{m.content}"
        "behaviour" -> "#{agent_name}: (behaviour: #{m.content})"
      end
    end)
    |> Enum.join("\n")
  end

  defp raise_if_blank!(field, name) when is_binary(name) do
    if String.trim(name) == "" do
      raise ArgumentError, "#{field} must be a non-blank string, got #{inspect(name)}"
    end

    :ok
  end

  defp raise_if_blank!(field, other) do
    raise ArgumentError, "#{field} must be a non-blank string, got #{inspect(other)}"
  end
end
