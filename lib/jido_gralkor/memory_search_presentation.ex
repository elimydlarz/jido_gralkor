defmodule JidoGralkor.MemorySearchPresentation do
  @moduledoc """
  Render structured search results as readable text for the consuming agent.

  Every memory is one line of plain text under the heading of whoever wrote it:
  `Lens: <name>`, `Reflection: <name>`, a direct source kind, or `Source: unknown`.
  Entities have no single writer, so they come last under `Entities`. Whole
  Reflection artefacts come first, then facts, then episodes, and that one order
  sets both the heading order and which memories survive the response limits.

  Structured content becomes readable text without knowing any Reflection's
  shape: an object with a `content` string shows only that text, an object with
  one field shows that field's value, any other object shows `key: value` pairs,
  and each item of a top-level list is its own bullet. A fact with an invalidation
  or expiry date says when with `(invalidated at <date>)`.

  A memory is cut only past 4,000 characters, and says so. The complete text fits
  Jido AI's 16,384-character string limit and the supplied UTF-8 byte budget for
  its serialized success envelope. Memories are retained or omitted whole, with
  one notice giving the total omitted. Canonical search data is unchanged.
  """

  @type output :: %{result: String.t()}
  @max_chars 16_384
  @max_memory_chars 4_000
  @entities_heading "Entities"

  @spec validate_max_bytes!(term()) :: pos_integer()
  def validate_max_bytes!(max_bytes) when is_integer(max_bytes) and max_bytes > 0, do: max_bytes

  def validate_max_bytes!(max_bytes) do
    raise ArgumentError,
          "memory_search_max_bytes must be a positive integer, got: #{inspect(max_bytes)}"
  end

  @spec for_model([Gralkor.Search.result()], pos_integer()) :: {:ok, output()} | {:error, term()}
  def for_model(results, max_bytes) do
    validate_max_bytes!(max_bytes)
    memories = memories(results)
    total = length(memories)
    minimum_bytes = envelope_bytes(output([], total))
    complete = output(memories, total)

    cond do
      fits?(complete, max_bytes) ->
        {:ok, complete}

      minimum_bytes > max_bytes ->
        {:error,
         {:memory_search_budget_too_small, %{max_bytes: max_bytes, minimum_bytes: minimum_bytes}}}

      true ->
        selected =
          Enum.reduce(memories, [], fn memory, selected ->
            candidate = selected ++ [memory]

            if fits?(output(candidate, total), max_bytes),
              do: candidate,
              else: selected
          end)

        {:ok, output(selected, total)}
    end
  end

  # Each memory is `{headings, text}`; a fact with several sources has several headings.
  defp memories(results) do
    episodes = Enum.flat_map(results, &Map.get(&1, :episodes, []))
    {artefacts, episodes} = Enum.split_with(episodes, &Map.has_key?(&1, :artefact))

    Enum.flat_map(artefacts, &artefact_memories/1) ++
      Enum.map(Enum.flat_map(results, &Map.get(&1, :facts, [])), &fact_memory/1) ++
      Enum.map(Enum.flat_map(results, &Map.get(&1, :nodes, [])), &entity_memory/1) ++
      Enum.flat_map(episodes, &episode_memories/1)
  end

  defp artefact_memories(%{artefact: %{payload: payload}} = episode) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
    |> bullets()
    |> Enum.map(&{[heading(episode)], one_line(&1)})
    |> reject_blank()
  end

  defp fact_memory(fact), do: {fact_headings(fact), one_line(fact.fact) <> invalidation(fact)}

  defp invalidation(fact) do
    case Map.get(fact, :invalid_at) || Map.get(fact, :expired_at) do
      nil -> ""
      moment -> " (invalidated at #{moment |> to_string() |> String.slice(0, 10)})"
    end
  end

  defp entity_memory(node) do
    name = Map.get(node, :name) || Map.get(node, :id) || "unnamed entity"
    summary = Map.get(node, :summary)
    attributes = Map.get(node, :attributes) || Map.get(node, :properties) || %{}

    text = if summary in [nil, ""], do: name, else: "#{name}: #{summary}"

    if attributes == %{} do
      {[@entities_heading], one_line(text)}
    else
      pairs =
        Enum.map_join(Enum.sort_by(attributes, &to_string(elem(&1, 0))), ", ", fn {key, value} ->
          "#{key}: #{value}"
        end)

      {[@entities_heading], one_line("#{text} (#{pairs})")}
    end
  end

  defp episode_memories(episode) do
    content = to_string(Map.get(episode, :content, ""))

    episode
    |> Map.get(:source_kind)
    |> episode_bullets(content)
    |> Enum.map(&{[heading(episode)], one_line(&1)})
    |> reject_blank()
  end

  defp episode_bullets(kind, content) when kind in [:structured_record, "structured_record"] do
    case Jason.decode(content) do
      {:ok, value} -> bullets(value)
      {:error, _} -> [content]
    end
  end

  defp episode_bullets(_kind, content), do: [content]

  defp reject_blank(memories), do: Enum.reject(memories, fn {_headings, text} -> text == "" end)

  defp bullets(value) when is_list(value), do: Enum.flat_map(value, &bullets/1)
  defp bullets(%{"content" => content}) when is_binary(content), do: [content]

  defp bullets(value) when is_map(value) and map_size(value) == 1,
    do: value |> Map.values() |> hd() |> bullets()

  defp bullets(value), do: [readable(value)]

  defp readable(value) when is_binary(value), do: value
  defp readable(value) when is_list(value), do: Enum.map_join(value, ", ", &readable/1)
  defp readable(%{"content" => content}) when is_binary(content), do: content

  defp readable(value) when is_map(value) do
    value
    |> Enum.reject(fn {_key, field} -> is_nil(field) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("; ", fn {key, field} -> "#{key}: #{readable(field)}" end)
  end

  defp readable(value), do: to_string(value)

  defp one_line(text) do
    text = text |> String.split() |> Enum.join(" ")

    if String.length(text) > @max_memory_chars,
      do: String.slice(text, 0, @max_memory_chars) <> "… (truncated)",
      else: text
  end

  defp output(memories, total) do
    sections =
      memories
      |> group_by_heading()
      |> Enum.map(fn {heading, texts} ->
        heading <> "\n" <> Enum.map_join(texts, "\n", &"- #{&1}")
      end)

    sections =
      case {total - length(memories), sections} do
        {0, []} -> ["No matching memory."]
        {0, sections} -> sections
        {1, sections} -> sections ++ ["1 more memory omitted (response limit)."]
        {omitted, sections} -> sections ++ ["#{omitted} more memories omitted (response limit)."]
      end

    %{result: Enum.join(sections, "\n\n")}
  end

  defp group_by_heading(memories) do
    groups =
      Enum.reduce(memories, [], fn {headings, text}, groups ->
        Enum.reduce(headings, groups, fn heading, groups ->
          case List.keyfind(groups, heading, 0) do
            nil -> groups ++ [{heading, [text]}]
            {^heading, texts} -> List.keyreplace(groups, heading, 0, {heading, texts ++ [text]})
          end
        end)
      end)

    {entities, writers} = Enum.split_with(groups, &(elem(&1, 0) == @entities_heading))
    writers ++ entities
  end

  defp fact_headings(fact) do
    headings = fact |> Map.get(:sources, []) |> Enum.flat_map(&named_heading/1) |> Enum.uniq()
    if headings == [], do: ["Source: unknown"], else: headings
  end

  defp heading(source), do: source |> named_heading() |> List.first("Source: unknown")

  defp named_heading(%{lens: name}) when is_binary(name) and name != "", do: ["Lens: #{name}"]

  defp named_heading(%{reflection: name}) when is_binary(name) and name != "",
    do: ["Reflection: #{name}"]

  defp named_heading(source), do: List.wrap(direct_heading(source))

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
