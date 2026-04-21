defmodule JidoGralkor.Canonical do
  @moduledoc """
  Converts a Jido/ReAct turn into Gralkor's canonical message shape.

  Gralkor accepts a flat list of `%Gralkor.Message{role, content}` where
  `role ∈ {"user", "assistant", "behaviour"}`. Adapter responsibility:

    * strip adapter-injected text the server should never see
      (the `<gralkor-memory>…</gralkor-memory>` recall envelope);
    * render the Jido ReAct event trace into `"behaviour"` messages
      using whatever textual form reads well for distillation;
    * filter events that aren't memory-worthy.

  The server never branches on interior structure — only on role. The
  LLM is forgiving about the exact `behaviour` wording, so the rendering
  here is free to evolve.
  """

  alias Gralkor.Message

  @memory_prefix ~r/<gralkor-memory[\s\S]*?<\/gralkor-memory>\n*/

  @doc """
  Normalise a Jido/ReAct turn into a list of canonical Gralkor messages.

  Returns `[]` when there's nothing worth persisting — callers use that
  to skip the capture call entirely.
  """
  @spec to_messages(String.t() | nil, list(map()), String.t() | nil) :: [Message.t()]
  def to_messages(user_query, events, assistant_answer) do
    []
    |> maybe_append_user(user_query)
    |> append_behaviours(events || [])
    |> maybe_append_assistant(assistant_answer)
  end

  defp maybe_append_user(messages, nil), do: messages

  defp maybe_append_user(messages, query) when is_binary(query) do
    cleaned = query |> strip_memory_prefix() |> String.trim()

    if cleaned == "" do
      messages
    else
      messages ++ [Message.new("user", cleaned)]
    end
  end

  defp maybe_append_assistant(messages, nil), do: messages

  defp maybe_append_assistant(messages, answer) when is_binary(answer) do
    trimmed = String.trim(answer)

    if trimmed == "" do
      messages
    else
      messages ++ [Message.new("assistant", trimmed)]
    end
  end

  defp append_behaviours(messages, events) do
    events
    |> Enum.flat_map(&render_event/1)
    |> Enum.reduce(messages, fn content, acc -> acc ++ [Message.new("behaviour", content)] end)
  end

  defp render_event(%{kind: :llm_completed, data: data}) do
    case extract_text(data) do
      "" -> []
      text -> ["thought: " <> text]
    end
  end

  defp render_event(%{kind: :tool_completed, data: data}) do
    name = Map.get(data, :tool_name) || Map.get(data, "tool_name") || "tool"
    input = Map.get(data, :input) || Map.get(data, "input")
    result = Map.get(data, :result) || Map.get(data, "result")

    input_part =
      case input do
        nil -> ""
        "" -> ""
        other -> "(" <> inspect(other) <> ")"
      end

    result_part =
      case result do
        nil -> ""
        "" -> ""
        other -> " → " <> format_result(other)
      end

    ["tool " <> name <> input_part <> result_part]
  end

  defp render_event(%{kind: _}), do: []
  defp render_event(_), do: []

  defp extract_text(data) when is_map(data) do
    value =
      Map.get(data, :content) ||
        Map.get(data, "content") ||
        Map.get(data, :text) ||
        Map.get(data, "text") ||
        ""

    cond do
      is_binary(value) -> String.trim(value)
      is_list(value) -> value |> Enum.map_join(" ", &stringify_block/1) |> String.trim()
      true -> value |> inspect() |> String.trim()
    end
  end

  defp extract_text(_), do: ""

  defp stringify_block(%{text: text}) when is_binary(text), do: text
  defp stringify_block(%{"text" => text}) when is_binary(text), do: text
  defp stringify_block(other) when is_binary(other), do: other
  defp stringify_block(other), do: inspect(other)

  defp format_result({:ok, inner}), do: "ok " <> format_result(inner)
  defp format_result({:error, inner}), do: "error " <> format_result(inner)
  defp format_result(value) when is_binary(value), do: value
  defp format_result(value), do: inspect(value)

  defp strip_memory_prefix(query), do: Regex.replace(@memory_prefix, query, "")
end
