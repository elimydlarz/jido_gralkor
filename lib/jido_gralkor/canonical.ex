defmodule JidoGralkor.Canonical do
  @moduledoc """
  Converts a Jido/ReAct turn into Gralkor's canonical message shape.

  Gralkor accepts a flat list of `%Gralkor.Message{role, content}` where
  `role ∈ {"user", "assistant", "behaviour"}`. Adapter responsibility:

    * render the Jido ReAct event trace into `"behaviour"` messages
      using whatever textual form reads well for distillation;
    * filter events that aren't memory-worthy.

  The `user_query` passed in is expected to be the user's actual words —
  not enriched with memory blocks, identity envelopes, or any other
  harness-injected context. In the hexagonal split, prompt-time
  enrichment belongs in a `Jido.AI.Reasoning.ReAct.RequestTransformer`
  that wraps context for the LLM but leaves `:query` alone, so downstream
  state (buffer, request store, capture) never carries injected junk.

  The server never branches on interior structure — only on role. The
  LLM is forgiving about the exact `behaviour` wording, so the rendering
  here is free to evolve.
  """

  alias Gralkor.Message

  @type outcome :: {:completed, String.t()} | {:failed, term()}

  @doc """
  Normalise a Jido/ReAct turn into a list of canonical Gralkor messages.

  Returns `[]` when there's nothing worth persisting — callers use that
  to skip the capture call entirely.
  """
  @spec to_messages(String.t(), list(map()), outcome()) :: [Message.t()]
  def to_messages(user_query, events, outcome) do
    []
    |> prepend_message("user", user_query)
    |> prepend_behaviours(events)
    |> prepend_outcome(outcome)
    |> Enum.reverse()
  end

  defp prepend_message(messages, role, content) do
    case String.trim(content) do
      "" -> messages
      trimmed -> [Message.new(role, trimmed) | messages]
    end
  end

  defp prepend_outcome(messages, {:completed, answer}) when is_binary(answer) do
    prepend_message(messages, "assistant", answer)
  end

  defp prepend_outcome(messages, {:failed, error}) do
    [Message.new("behaviour", "request failed: " <> format_result(error)) | messages]
  end

  defp prepend_behaviours(messages, events) do
    events
    |> Enum.flat_map(&render_event/1)
    |> Enum.reduce(messages, fn content, acc -> [Message.new("behaviour", content) | acc] end)
  end

  defp render_event(%{kind: :llm_completed, data: %{tool_calls: [_ | _]} = data}) do
    case extract_text(data) do
      "" -> []
      text -> ["thought: " <> text]
    end
  end

  defp render_event(%{kind: :llm_completed}), do: []

  defp render_event(%{kind: :tool_completed, data: data}) do
    name = Map.get(data, :tool_name, "tool")

    result_part =
      case Map.get(data, :result) do
        nil -> ""
        "" -> ""
        other -> " → " <> format_result(other)
      end

    ["tool " <> name <> result_part]
  end

  defp render_event(_), do: []

  defp extract_text(data) when is_map(data) do
    case Map.get(data, :text, "") do
      value when is_binary(value) -> String.trim(value)
      value when is_list(value) -> value |> Enum.map_join(" ", &stringify_block/1) |> String.trim()
      value -> value |> inspect() |> String.trim()
    end
  end

  defp stringify_block(%{text: text}) when is_binary(text), do: text
  defp stringify_block(other) when is_binary(other), do: other
  defp stringify_block(other), do: inspect(other)

  defp format_result({:ok, inner}), do: "ok " <> format_result(inner)
  defp format_result({:error, inner}), do: "error " <> format_result(inner)
  defp format_result(value) when is_binary(value), do: value
  defp format_result(value), do: inspect(value)
end
