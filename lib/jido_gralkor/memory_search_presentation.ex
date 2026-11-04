defmodule JidoGralkor.MemorySearchPresentation do
  @moduledoc """
  Render structured search results as readable text for the consuming agent.

  Every memory is one bullet under the heading of whoever wrote it:
  `Lens: <name>`, `Reflection: <name>`, a direct source kind, or `Source: unknown`.
  Entities have no single writer, so they come last under `Entities`. Whole
  Reflection artefacts come first, then facts, then episodes, and that one order
  sets both the heading order and which memories survive the response limits.

  A bullet's first line is the memory's main text: the fact text, `name: summary`
  for an entity, an object's `content` string, or else an object's first field
  as `key: value`. Every other field the memory carries (the payload fields of a
  Reflection artefact or structured-record episode, and an entity's attributes)
  follows on its own indented `key: value` line: one-line fields first, then
  nested ones, each group alphabetical. A list of plain values stays on one line;
  a list containing an object becomes nested bullets laid out the same way, and a
  nested object becomes `key:` followed by its own fields. Null and empty values
  are left out. A payload object with exactly one key is presented as that key's
  value, and each item of a top-level list is its own bullet. Nothing depends on
  any Reflection's or entity type's shape, and record metadata never appears.

  A fact or episode's first line ends with when it was true and where it came
  from: `(valid from <date>)`, or `(valid from <date> to <date>)` once it was
  invalidated or expired, then `; source: <description>`. The start is when it
  became true, or when it was recorded if that is missing. A source description
  never repeats its Lens marker, and one that only names a Reflection is left out.

  A memory is cut only past 4,000 characters, counting all of its lines, and says
  so; the date and source follow the cut. The complete text fits
  Jido AI's 16,384-character string limit and the supplied UTF-8 byte budget for
  its serialized success envelope. Memories are retained or omitted whole, with
  one notice giving the total omitted. Canonical search data is unchanged.
  """

  @type output :: %{result: String.t()}
  @max_chars 16_384
  @max_memory_chars 4_000
  @entities_heading "Entities"
  @main_text_field "content"

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
    |> structured_memories(episode)
  end

  defp structured_memories(value, episode) do
    value
    |> unwrap()
    |> List.wrap()
    |> Enum.map(&prune/1)
    |> Enum.reject(&(&1 == :empty))
    |> Enum.map(&{[heading(episode)], memory_text(lines(&1))})
    |> with_details(episode, [episode])
  end

  # A payload's single outer key only names the Reflection's output field.
  defp unwrap(value) when is_map(value) and map_size(value) == 1,
    do: value |> Map.values() |> hd()

  defp unwrap(value), do: value

  defp fact_memory(fact),
    do:
      {fact_headings(fact),
       fact.fact
       |> one_line()
       |> memory_text()
       |> append_details(details(fact, Map.get(fact, :sources, [])))}

  defp with_details(memories, record, sources) do
    Enum.map(memories, fn {headings, text} ->
      {headings, append_details(text, details(record, sources))}
    end)
  end

  # The date and source suffix ends the bullet's first line.
  defp append_details(text, details) do
    case String.split(text, "\n", parts: 2) do
      [first] -> first <> details
      [first, rest] -> first <> details <> "\n" <> rest
    end
  end

  defp details(record, sources) do
    case Enum.reject([validity(record), source(sources)], &is_nil/1) do
      [] -> ""
      parts -> " (" <> Enum.join(parts, "; ") <> ")"
    end
  end

  defp validity(record) do
    from = date(Map.get(record, :valid_at) || Map.get(record, :created_at))
    to = date(Map.get(record, :invalid_at) || Map.get(record, :expired_at))

    case {from, to} do
      {nil, nil} -> nil
      {from, nil} -> "valid from #{from}"
      {nil, to} -> "valid until #{to}"
      {from, to} -> "valid from #{from} to #{to}"
    end
  end

  defp date(nil), do: nil
  defp date(""), do: nil
  defp date(moment), do: moment |> to_string() |> String.slice(0, 10)

  defp source(sources) do
    sources
    |> Enum.map(&source_description/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      descriptions -> "source: " <> Enum.join(descriptions, ", ")
    end
  end

  defp source_description(source) do
    description =
      source
      |> Map.get(:source_description)
      |> to_string()
      |> String.replace(~r/ \[lens: .+\]$/s, "")
      |> String.replace_suffix(" [gralkor: direct]", "")
      |> one_line()

    if description == "" or String.starts_with?(description, "reflection:"),
      do: nil,
      else: description
  end

  defp entity_memory(node) do
    name = one_line(Map.get(node, :name) || Map.get(node, :id) || "unnamed entity")
    summary = one_line(Map.get(node, :summary))
    first = if summary == "", do: name, else: "#{name}: #{summary}"

    attributes =
      (Map.get(node, :attributes) || Map.get(node, :properties) || %{})
      |> Enum.reject(fn {key, _value} ->
        key |> to_string() |> String.starts_with?("_gralkor")
      end)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    fields =
      case prune(attributes) do
        :empty -> []
        pruned -> field_lines(pruned)
      end

    {[@entities_heading], memory_text([first | fields])}
  end

  defp episode_memories(episode) do
    content = to_string(Map.get(episode, :content, ""))

    if Map.get(episode, :source_kind) in [:structured_record, "structured_record"] do
      case Jason.decode(content) do
        {:ok, value} -> structured_memories(value, episode)
        {:error, _} -> plain_episode_memories(content, episode)
      end
    else
      plain_episode_memories(content, episode)
    end
  end

  defp plain_episode_memories(content, episode) do
    case one_line(content) do
      "" -> []
      text -> with_details([{[heading(episode)], memory_text(text)}], episode, [episode])
    end
  end

  # Pruning drops null, blank, and empty values, and anything containing only those.
  defp prune(nil), do: :empty

  defp prune(value) when is_binary(value) do
    case one_line(value) do
      "" -> :empty
      text -> text
    end
  end

  defp prune(value) when is_list(value) do
    case value |> Enum.map(&prune/1) |> Enum.reject(&(&1 == :empty)) do
      [] -> :empty
      items -> items
    end
  end

  defp prune(value) when is_map(value) do
    value
    |> Enum.map(fn {key, field} -> {one_line(to_string(key)), prune(field)} end)
    |> Enum.reject(fn {_key, field} -> field == :empty end)
    |> case do
      [] -> :empty
      fields -> Map.new(fields)
    end
  end

  defp prune(value), do: value

  # The lines of one pruned value, relative to its bullet's text column.
  defp lines(value) when is_map(value) do
    case Map.pop(value, @main_text_field) do
      {main, rest} when is_binary(main) -> [main | field_lines(rest)]
      _ -> field_lines(value)
    end
  end

  defp lines(value) when is_list(value) do
    if Enum.all?(value, &plain?/1),
      do: [plain_list(value)],
      else: nested_bullets(value)
  end

  defp lines(value), do: [to_string(value)]

  defp field_lines(fields) do
    {one_line, nested} =
      fields |> Enum.sort_by(&elem(&1, 0)) |> Enum.split_with(&one_line_field?/1)

    Enum.flat_map(one_line, fn {key, value} -> ["#{key}: #{plain_list(List.wrap(value))}"] end) ++
      Enum.flat_map(nested, fn
        {key, value} when is_list(value) -> ["#{key}:" | nested_bullets(value)]
        {key, value} -> ["#{key}:" | Enum.map(lines(value), &("  " <> &1))]
      end)
  end

  defp nested_bullets(items) do
    Enum.flat_map(items, fn item ->
      [first | rest] = lines(item)
      ["- " <> first | Enum.map(rest, &("  " <> &1))]
    end)
  end

  defp one_line_field?({_key, value}) when is_list(value), do: Enum.all?(value, &plain?/1)
  defp one_line_field?({_key, value}), do: plain?(value)

  defp plain?(value), do: not is_map(value) and not is_list(value)

  defp plain_list(values), do: Enum.map_join(values, ", ", &to_string/1)

  defp one_line(nil), do: ""
  defp one_line(text), do: text |> to_string() |> String.split() |> Enum.join(" ")

  # The bullet's text: its first line, then each other line under the text column,
  # cut past 4,000 characters counting every line.
  defp memory_text(text) when is_binary(text), do: memory_text([text])

  defp memory_text([first | rest]) do
    text = Enum.join([first | Enum.map(rest, &("  " <> &1))], "\n")

    if String.length(text) > @max_memory_chars,
      do: String.trim_trailing(String.slice(text, 0, @max_memory_chars)) <> "… (truncated)",
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
            nil ->
              groups ++ [{heading, [text]}]

            {^heading, texts} ->
              if text in texts,
                do: groups,
                else: List.keyreplace(groups, heading, 0, {heading, texts ++ [text]})
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
