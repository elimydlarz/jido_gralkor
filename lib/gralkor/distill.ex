defmodule Gralkor.Distill do
  @moduledoc """
  Render a list of conversation turns into the transcript episode body ingested
  into the knowledge graph.

  The transcript keeps **only** user/assistant text. Behaviour (the agent's
  reasoning, tool calls, tool results) is never woven in: a turn marked for
  experiential learning routes its reasoning into a separate
  `Gralkor.AgentLearning` episode (see `Gralkor.Learn`), and non-ERL turns drop
  it. Rendering is pure — there is no LLM call.

  See `ex-format-transcript` in `TEST_TREES.md`.
  """

  alias Gralkor.Message

  @type turn :: [Message.t()]

  @doc """
  Render `turns` (a list of turns; each turn a list of canonical Messages) into
  the transcript episode body — user and assistant lines only.

  `agent_name` labels assistant lines (`"Susu: hello"`); `user_name` labels user
  lines (`"Eli: hi"`). Both are required and non-blank — the transcript is fed
  to graphiti's entity extraction, where a generic "User:" label would collapse
  every user across the deployment into a single node.
  """
  @spec format_transcript([turn()], String.t(), String.t()) :: String.t()
  def format_transcript(turns, agent_name, user_name) when is_list(turns) do
    raise_if_blank!(:agent_name, agent_name)
    raise_if_blank!(:user_name, user_name)

    turns
    |> Enum.map(&render_turn(&1, agent_name, user_name))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # ── internal ────────────────────────────────────────────────

  defp render_turn(turn, agent_name, user_name) do
    turn
    |> Enum.flat_map(fn m ->
      case m.role do
        "user" -> ["#{user_name}: #{m.content}"]
        "assistant" -> ["#{agent_name}: #{m.content}"]
        "behaviour" -> []
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
