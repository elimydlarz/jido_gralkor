defmodule JidoGralkor.MemorySearchPresentation do
  @moduledoc """
  Render structured fact search results as source headings and fact bullets.

  The complete text fits Jido AI's 16,384-character string limit and the supplied
  UTF-8 byte budget for its serialized success envelope. Facts are retained or
  omitted whole, with an explicit omission notice. Canonical search data is unchanged.
  """

  @type output :: %{result: String.t()}
  @max_chars 16_384

  @spec validate_max_bytes!(term()) :: pos_integer()
  def validate_max_bytes!(max_bytes) when is_integer(max_bytes) and max_bytes > 0, do: max_bytes

  def validate_max_bytes!(max_bytes) do
    raise ArgumentError,
          "memory_search_max_bytes must be a positive integer, got: #{inspect(max_bytes)}"
  end

  @spec for_model([Gralkor.Search.result()], pos_integer()) :: {:ok, output()} | {:error, term()}
  def for_model(results, max_bytes) do
    validate_max_bytes!(max_bytes)
    total = length(results)
    minimum_bytes = envelope_bytes(output([], total))

    complete = output(results, total)

    cond do
      fits?(complete, max_bytes) ->
        {:ok, complete}

      minimum_bytes > max_bytes ->
        {:error,
         {:memory_search_budget_too_small, %{max_bytes: max_bytes, minimum_bytes: minimum_bytes}}}

      true ->
        selected =
          Enum.reduce(results, [], fn result, selected ->
            candidate = selected ++ [result]
            rendered = output(candidate, total)

            if fits?(rendered, max_bytes),
              do: candidate,
              else: selected
          end)

        {:ok, output(selected, total)}
    end
  end

  defp output(results, total) do
    groups =
      Enum.reduce(results, [], fn %{fact: fact}, groups ->
        Enum.reduce(source_headings(fact), groups, fn heading, groups ->
          case List.keyfind(groups, heading, 0) do
            nil ->
              groups ++ [{heading, [fact.fact]}]

            {^heading, facts} ->
              List.keyreplace(groups, heading, 0, {heading, facts ++ [fact.fact]})
          end
        end)
      end)

    sections =
      Enum.map(groups, fn {heading, facts} ->
        heading <> "\n" <> Enum.map_join(facts, "\n", &"- #{&1}")
      end)

    omitted = total - length(results)

    sections =
      cond do
        omitted > 0 -> sections ++ ["Omitted facts: #{omitted} (response limit)."]
        sections == [] -> ["No matching facts."]
        true -> sections
      end

    %{result: Enum.join(sections, "\n\n")}
  end

  defp source_headings(fact) do
    headings =
      fact
      |> Map.get(:sources, [])
      |> Enum.flat_map(fn
        %{lens: name} when is_binary(name) and name != "" -> ["Lens: #{name}"]
        %{reflection: name} when is_binary(name) and name != "" -> ["Reflection: #{name}"]
        _ -> []
      end)
      |> Enum.uniq()

    if headings == [], do: ["Source: unknown"], else: headings
  end

  defp fits?(output, max_bytes),
    do: String.length(output.result) <= @max_chars and envelope_bytes(output) <= max_bytes

  defp envelope_bytes(output), do: byte_size(Jason.encode!(%{ok: true, result: output}))
end
