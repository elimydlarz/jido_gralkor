defmodule Gralkor.Format do
  @moduledoc """
  Format graphiti edge data into the canonical fact strings the LLM sees.

  Pure Elixir — graphiti runs in Python, but we extract its edges into
  Elixir maps and format them here, never reaching back into Python for
  formatting.

  Output shape per fact:

      - {fact} (created …) (valid from …) (invalid since …) (expired …)

  Timestamp normalisation matches the server's `pipelines/formatting.py` so
  consumers see identical fact text from either stack.

  See `test-trees/unit/format-fact_TEST_TREES.md`.
  """

  @fractional_seconds ~r/\.\d+/
  @trailing_z ~r/Z$/
  @tz_offset ~r/([+-])(\d{2}):(\d{2})$/

  @spec format_fact(map()) :: String.t()
  def format_fact(%{fact: fact} = m) do
    base = "- " <> fact

    base
    |> append_ts(m, :created_at, "created")
    |> append_ts(m, :valid_at, "valid from")
    |> append_ts(m, :invalid_at, "invalid since")
    |> append_ts(m, :expired_at, "expired")
    |> append_sources(m)
  end

  @spec format_timestamp(String.t()) :: String.t()
  def format_timestamp(ts) when is_binary(ts) do
    ts
    |> then(&Regex.replace(@fractional_seconds, &1, ""))
    |> then(&Regex.replace(@trailing_z, &1, "+0"))
    |> then(&compact_tz_offset/1)
  end

  defp compact_tz_offset(s) do
    Regex.replace(@tz_offset, s, fn _full, sign, hours_str, minutes_str ->
      hours = hours_str |> String.to_integer() |> Integer.to_string()

      if minutes_str == "00" do
        "#{sign}#{hours}"
      else
        "#{sign}#{hours}:#{minutes_str}"
      end
    end)
  end

  defp append_ts(acc, m, key, label) do
    case Map.get(m, key) do
      nil -> acc
      "" -> acc
      ts -> acc <> " (#{label} #{format_timestamp(ts)})"
    end
  end

  defp append_sources(acc, %{sources: sources}) when is_list(sources) do
    Enum.reduce(sources, acc, fn source, rendered ->
      kind = Map.get(source, "source_kind") || Map.get(source, :source_kind)
      description = Map.get(source, "source_description") || Map.get(source, :source_description)
      id = Map.get(source, "id") || Map.get(source, :id)
      rendered <> " (source: #{kind} — #{description}; episode: #{id})"
    end)
  end

  defp append_sources(acc, _fact), do: acc
end
