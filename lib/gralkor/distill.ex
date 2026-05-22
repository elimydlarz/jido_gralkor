defmodule Gralkor.Distill do
  @moduledoc """
  Render a list of conversation turns into an episode body suitable for
  ingesting into the knowledge graph.

  Each turn that contains a `"behaviour"` message gets distilled by the
  configured LLM into a first-person past-tense summary and rendered as
  `{agent_name}: (behaviour: {summary})` before the assistant text. Turns
  without behaviour skip the LLM entirely.

  Distillation per turn is best-effort: any failure (LLM error, exception)
  drops the behaviour line for that turn and preserves the user/assistant
  text — the surrounding turns still produce output.

  Turns with behaviour are distilled in parallel via `Task.async_stream`.

  See `ex-format-transcript` in `gralkor/TEST_TREES.md`.
  """

  alias Gralkor.Message

  @type turn :: [Message.t()]
  @type distill_fn :: (String.t() -> {:ok, String.t()} | {:error, term()}) | nil

  @parallel_timeout 60_000

  @doc """
  Render `turns` (a list of turns; each turn a list of canonical Messages)
  into the episode body string.

  `distill_fn` is the LLM caller used to summarise behaviour messages. Pass
  `nil` to skip distillation entirely (behaviour lines are silently omitted).

  `agent_name` is required and non-blank — used to label assistant and
  behaviour lines (e.g. `"Susu: hello"`, `"Susu: (behaviour: thought)"`).

  `user_name` is required and non-blank — used to label user lines
  (e.g. `"Eli: hi"`). The rendered transcript is fed to graphiti's entity
  extraction; a generic "User:" label collapses every user across the
  deployment into a single graph node, destroying graph quality. Every
  consumer must name the human.
  """
  @spec format_transcript([turn()], distill_fn(), String.t(), String.t()) :: String.t()
  def format_transcript(turns, distill_fn, agent_name, user_name) when is_list(turns) do
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    turns
    |> distill_in_parallel(distill_fn, agent_name, user_name)
    |> Enum.map(&render_turn(&1, agent_name, user_name))
    |> Enum.join("\n")
  end

  @doc """
  Schema for the structured-output response the LLM returns when distilling
  a behaviour-containing turn.
  """
  @spec distill_schema() :: keyword()
  def distill_schema do
    [
      behaviour: [
        type: :string,
        required: true,
        doc:
          "First-person past-tense summary of what the agent did during this turn (its thinking, tool calls, tool results)."
      ]
    ]
  end

  # ── internal ────────────────────────────────────────────────

  defp raise_if_blank!(field, name) when is_binary(name) do
    if String.trim(name) == "" do
      raise ArgumentError, "#{field} must be a non-blank string, got #{inspect(name)}"
    end

    :ok
  end

  defp raise_if_blank!(field, other) do
    raise ArgumentError, "#{field} must be a non-blank string, got #{inspect(other)}"
  end

  defp distill_in_parallel(turns, distill_fn, agent_name, user_name) do
    turns
    |> Enum.map(fn turn -> {turn, has_behaviour?(turn)} end)
    |> Task.async_stream(
      fn
        {turn, false} -> {turn, nil}
        {turn, true} -> {turn, safe_distill(distill_fn, turn, agent_name, user_name)}
      end,
      ordered: true,
      timeout: @parallel_timeout
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp has_behaviour?(turn), do: Enum.any?(turn, &(&1.role == "behaviour"))

  defp safe_distill(nil, _turn, _agent_name, _user_name), do: nil

  defp safe_distill(distill_fn, turn, agent_name, user_name) do
    distill_fn.(thinking_prompt(turn, agent_name, user_name))
  rescue
    _ -> {:error, :raised}
  catch
    _, _ -> {:error, :raised}
  else
    {:ok, summary} when is_binary(summary) -> {:ok, summary}
    {:error, _} = err -> err
    other -> {:error, {:unexpected_distill_response, other}}
  end

  defp thinking_prompt(turn, agent_name, user_name) do
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

  defp render_turn({turn, distill_result}, agent_name, user_name) do
    lines =
      turn
      |> Enum.reject(&(&1.role == "behaviour"))
      |> Enum.flat_map(fn m ->
        case m.role do
          "user" ->
            ["#{user_name}: #{m.content}"]

          "assistant" ->
            assistant_lines(distill_result, agent_name) ++ ["#{agent_name}: #{m.content}"]
        end
      end)
      |> ensure_behaviour_present(distill_result, agent_name)

    Enum.join(lines, "\n")
  end

  defp assistant_lines({:ok, summary}, agent_name),
    do: ["#{agent_name}: (behaviour: #{summary})"]

  defp assistant_lines(_, _), do: []

  # If a turn has behaviour but no assistant message, still emit the behaviour
  # line so the summary isn't dropped on the floor.
  defp ensure_behaviour_present(lines, {:ok, summary}, agent_name) do
    if Enum.any?(lines, &String.starts_with?(&1, "#{agent_name}: ")) do
      lines
    else
      lines ++ ["#{agent_name}: (behaviour: #{summary})"]
    end
  end

  defp ensure_behaviour_present(lines, _, _), do: lines
end
