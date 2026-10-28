defmodule JidoGralkor.MemorySearchPresentation do
  @moduledoc """
  Render structured search results as readable text for the consuming agent.

  Facts from every Destination come first under a `Facts` heading, grouped under
  source headings (`Lens: <name>`, `Reflection: <name>`, direct source kind, or
  `Source: unknown`). Entities follow under `Entities`, one complete bullet each.
  Episodes follow under `Episodes`, compactly: a writer label and a bounded
  excerpt, a Reflection episode summarised by its artefact identifier and a
  bounded payload excerpt, so whole source documents never flood the agent's
  context.

  The complete text fits Jido AI's 16,384-character string limit and the supplied
  UTF-8 byte budget for its serialized success envelope. Bullets are retained or
  omitted whole, with an explicit omission notice counting each kind. Canonical
  search data is unchanged.
  """

  @type output :: %{result: String.t()}
  @max_chars 16_384
  @excerpt_chars 280

  @spec validate_max_bytes!(term()) :: pos_integer()
  def validate_max_bytes!(max_bytes) when is_integer(max_bytes) and max_bytes > 0, do: max_bytes

  def validate_max_bytes!(max_bytes) do
    raise ArgumentError,
          "memory_search_max_bytes must be a positive integer, got: #{inspect(max_bytes)}"
  end

  @spec for_model([Gralkor.Search.result()], pos_integer()) :: {:ok, output()} | {:error, term()}
  def for_model(results, max_bytes) do
    validate_max_bytes!(max_bytes)
    items = items(results)
    totals = count(items)
    minimum_bytes = envelope_bytes(output([], totals))
    complete = output(items, totals)

    cond do
      fits?(complete, max_bytes) ->
        {:ok, complete}

      minimum_bytes > max_bytes ->
        {:error,
         {:memory_search_budget_too_small, %{max_bytes: max_bytes, minimum_bytes: minimum_bytes}}}

      true ->
        selected =
          Enum.reduce(items, [], fn item, selected ->
            candidate = selected ++ [item]

            if fits?(output(candidate, totals), max_bytes),
              do: candidate,
              else: selected
          end)

        {:ok, output(selected, totals)}
    end
  end

  defp items(results) do
    facts = for result <- results, fact <- Map.get(result, :facts, []), do: {:fact, fact}
    nodes = for result <- results, node <- Map.get(result, :nodes, []), do: {:entity, node}

    episodes =
      for result <- results, episode <- Map.get(result, :episodes, []), do: {:episode, episode}

    facts ++ nodes ++ episodes
  end

  defp count(items) do
    Enum.reduce(items, %{fact: 0, entity: 0, episode: 0}, fn {kind, _}, counts ->
      Map.update!(counts, kind, &(&1 + 1))
    end)
  end

  defp output(items, totals) do
    shown = count(items)
    by_kind = Enum.group_by(items, &elem(&1, 0), &elem(&1, 1))

    sections =
      [
        facts_section(Map.get(by_kind, :fact, [])),
        bullets_section("Entities", Map.get(by_kind, :entity, []), &entity_bullet/1),
        bullets_section("Episodes", Map.get(by_kind, :episode, []), &episode_bullet/1)
      ]
      |> Enum.reject(&is_nil/1)

    omitted = Map.new(totals, fn {kind, total} -> {kind, total - Map.fetch!(shown, kind)} end)

    sections =
      cond do
        Enum.any?(omitted, fn {_kind, n} -> n > 0 end) ->
          sections ++
            [
              "Omitted (response limit): facts #{omitted.fact}, entities #{omitted.entity}, episodes #{omitted.episode}."
            ]

        sections == [] ->
          ["No matching memory."]

        true ->
          sections
      end

    %{result: Enum.join(sections, "\n\n")}
  end

  defp facts_section([]), do: nil

  defp facts_section(facts) do
    groups =
      Enum.reduce(facts, [], fn fact, groups ->
        Enum.reduce(source_headings(fact), groups, fn heading, groups ->
          case List.keyfind(groups, heading, 0) do
            nil ->
              groups ++ [{heading, [fact.fact]}]

            {^heading, texts} ->
              List.keyreplace(groups, heading, 0, {heading, texts ++ [fact.fact]})
          end
        end)
      end)

    "Facts\n\n" <>
      Enum.map_join(groups, "\n\n", fn {heading, texts} ->
        heading <> "\n" <> Enum.map_join(texts, "\n", &"- #{&1}")
      end)
  end

  defp bullets_section(_heading, [], _bullet), do: nil

  defp bullets_section(heading, values, bullet),
    do: heading <> "\n" <> Enum.map_join(values, "\n", bullet)

  defp entity_bullet(node) do
    name = Map.get(node, :name) || Map.get(node, :id) || "unnamed entity"
    summary = Map.get(node, :summary)
    attributes = Map.get(node, :attributes) || Map.get(node, :properties) || %{}

    text = if summary in [nil, ""], do: "- #{name}", else: "- #{name}: #{summary}"

    if attributes == %{} do
      text
    else
      text <>
        " (" <>
        Enum.map_join(Enum.sort_by(attributes, &to_string(elem(&1, 0))), ", ", fn {key, value} ->
          "#{key}: #{value}"
        end) <> ")"
    end
  end

  defp episode_bullet(%{artefact: %{id: id, payload: payload}} = episode) do
    "- [#{episode_label(episode)}] artefact #{id}: #{excerpt(Jason.encode!(payload))}"
  end

  defp episode_bullet(episode) do
    "- [#{episode_label(episode)}] #{excerpt(to_string(Map.get(episode, :content, "")))}"
  end

  defp episode_label(%{lens: name}) when is_binary(name) and name != "", do: "Lens: #{name}"

  defp episode_label(%{reflection: name}) when is_binary(name) and name != "",
    do: "Reflection: #{name}"

  defp episode_label(source), do: direct_heading(source) || "Source: unknown"

  defp excerpt(text) do
    text = text |> String.split() |> Enum.join(" ")

    if String.length(text) > @excerpt_chars,
      do: String.slice(text, 0, @excerpt_chars) <> "… (truncated)",
      else: text
  end

  defp source_headings(fact) do
    headings =
      fact
      |> Map.get(:sources, [])
      |> Enum.flat_map(fn
        %{lens: name} when is_binary(name) and name != "" -> ["Lens: #{name}"]
        %{reflection: name} when is_binary(name) and name != "" -> ["Reflection: #{name}"]
        source -> List.wrap(direct_heading(source))
      end)
      |> Enum.uniq()

    if headings == [], do: ["Source: unknown"], else: headings
  end

  defp direct_heading(%{writer: :direct, source_kind: kind})
       when kind in [:conversation, "conversation"],
       do: "Source: direct conversation"

  defp direct_heading(%{writer: :direct, source_kind: kind}) when kind in [:document, "document"],
    do: "Source: direct document"

  defp direct_heading(%{writer: :direct, source_kind: kind})
       when kind in [:structured_record, "structured_record"],
       do: "Source: direct structured record"

  defp direct_heading(%{writer: :direct}), do: "Source: direct"
  defp direct_heading(_source), do: nil

  defp fits?(output, max_bytes),
    do: String.length(output.result) <= @max_chars and envelope_bytes(output) <= max_bytes

  defp envelope_bytes(output), do: byte_size(Jason.encode!(%{ok: true, result: output}))
end
