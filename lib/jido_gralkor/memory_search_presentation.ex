defmodule JidoGralkor.MemorySearchPresentation do
  @moduledoc """
  Render structured search results as readable sections for the consuming agent.

  `sections/1` returns `%{heading:, text:}` sections. Every memory is one bullet in
  the section of whoever wrote it: `Lens: <name>` sections first, then
  `Reflection: <name>`, then a direct source kind or `Source: unknown`, each kind in
  first-appearance order. Entities have no single writer, so they follow in one
  `Entities in <Destination> memory` section for each Destination that returned
  entities. Inside a section, whole Reflection artefacts come first, then facts,
  then episodes. With nothing found there is one `Memory` section saying so.
  `text/1` joins sections into one text, each heading over its text.

  Each section has its own character limit, and no limit applies across sections:
  a Lens section's text stays within 12,000 characters, a Reflection's within
  8,000, and a Source's and an Entities section's within 6,000, all under
  Jido AI's 16,384-character string limit. A section over its limit keeps its
  memories in order while they fit with its omission notice, omits the rest whole,
  and ends with the number it omitted.

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
  so; the date and source follow the cut. Canonical search data is unchanged.
  """

  @type section :: %{heading: String.t(), text: String.t()}

  @max_memory_chars 4_000
  @main_text_field "content"
  @no_memory %{heading: "Memory", text: "No matching memory."}
  @limits %{lens: 12_000, reflection: 8_000, source: 6_000, entities: 6_000}

  @doc "The search results as sections: each Lens, Reflection, and Source, then each Destination's entities."
  @spec sections([Gralkor.Search.result()]) :: [section()]
  def sections(results) do
    case writer_sections(results) ++ entity_sections(results) do
      [] -> [@no_memory]
      sections -> sections
    end
  end

  @doc "The sections as one text: each heading over its text, separated by blank lines."
  @spec text([section()]) :: String.t()
  def text(sections),
    do:
      Enum.map_join(sections, "\n\n", fn %{heading: heading, text: text} ->
        heading <> "\n" <> text
      end)

  defp writer_sections(results) do
    results
    |> memories()
    |> group_by_heading()
    |> Enum.sort_by(fn {heading, _texts} -> heading_kind_order(heading) end)
    |> Enum.map(fn {heading, texts} -> section(heading, texts, heading_kind(heading)) end)
  end

  defp entity_sections(results) do
    results
    |> Enum.reject(&(Map.get(&1, :nodes, []) == []))
    |> Enum.map(fn result ->
      texts =
        result.nodes
        |> Enum.map(fn node -> node |> entity_memory() |> elem(1) end)
        |> Enum.reduce([], &add_text(&2, &1))

      section("Entities in #{result.destination} memory", texts, :entities)
    end)
  end

  defp heading_kind("Lens: " <> _), do: :lens
  defp heading_kind("Reflection: " <> _), do: :reflection
  defp heading_kind(_source), do: :source

  defp heading_kind_order(heading),
    do: Enum.find_index([:lens, :reflection, :source], &(&1 == heading_kind(heading)))

  defp section(heading, texts, kind) do
    limit = Map.fetch!(@limits, kind)
    complete = bullets(texts)

    if String.length(complete) <= limit do
      %{heading: heading, text: complete}
    else
      reserved = String.length("\n\n" <> omission(length(texts)))

      kept =
        Enum.reduce(texts, [], fn text, kept ->
          candidate = kept ++ [text]
          if String.length(bullets(candidate)) + reserved <= limit, do: candidate, else: kept
        end)

      notice = omission(length(texts) - length(kept))
      %{heading: heading, text: if(kept == [], do: notice, else: bullets(kept) <> "\n\n" <> notice)}
    end
  end

  defp bullets(texts), do: Enum.map_join(texts, "\n", &"- #{&1}")

  defp omission(1), do: "1 more memory omitted (section limit)."
  defp omission(count), do: "#{count} more memories omitted (section limit)."

  # Each memory is `{headings, text}`; a fact with several sources has several headings.
  defp memories(results) do
    episodes = Enum.flat_map(results, &Map.get(&1, :episodes, []))
    {artefacts, episodes} = Enum.split_with(episodes, &Map.has_key?(&1, :artefact))

    Enum.flat_map(artefacts, &artefact_memories/1) ++
      Enum.map(Enum.flat_map(results, &Map.get(&1, :facts, [])), &fact_memory/1) ++
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
    |> Enum.map(&memory([heading(episode)], lines(&1), details(episode, [episode])))
  end

  # A payload's single outer key only names the Reflection's output field.
  defp unwrap(value) when is_map(value) and map_size(value) == 1,
    do: value |> Map.values() |> hd()

  defp unwrap(value), do: value

  defp fact_memory(fact) do
    sources = Map.get(fact, :sources, [])
    memory(fact_headings(fact), [one_line(fact.fact)], details(fact, sources))
  end

  # Every memory is its headings and its text: the lines cut past 4,000 characters,
  # then the date and source suffix at the end of the first line.
  defp memory(headings, lines, details) do
    text =
      case lines |> memory_text() |> String.split("\n", parts: 2) do
        [first] -> first <> details
        [first, rest] -> first <> details <> "\n" <> rest
      end

    {headings, text}
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
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.reject(fn {key, _value} -> String.starts_with?(key, "_gralkor") end)

    fields =
      case prune(attributes) do
        :empty -> []
        pruned -> field_lines(pruned)
      end

    memory([], [first | fields], "")
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
      text -> [memory([heading(episode)], [text], details(episode, [episode]))]
    end
  end

  # Pruning drops null, blank, and empty values, and anything containing only those.
  defp prune(nil), do: :empty
  # A struct such as a DateTime is one plain value.
  defp prune(%_{} = value), do: prune(to_string(value))

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
  defp memory_text([first | rest]) do
    text = Enum.join([first | Enum.map(rest, &("  " <> &1))], "\n")

    if String.length(text) > @max_memory_chars,
      do: String.trim_trailing(String.slice(text, 0, @max_memory_chars)) <> "… (truncated)",
      else: text
  end

  defp group_by_heading(memories) do
    Enum.reduce(memories, [], fn {headings, text}, groups ->
      Enum.reduce(headings, groups, fn heading, groups ->
        case List.keyfind(groups, heading, 0) do
          nil ->
            groups ++ [{heading, [text]}]

          {^heading, texts} ->
            List.keyreplace(groups, heading, 0, {heading, add_text(texts, text)})
        end
      end)
    end)
  end

  # The same text appears once under one heading, and a memory that is only another
  # memory's first line adds nothing beside it: the longer memory is kept in place.
  defp add_text(texts, text) do
    cond do
      Enum.any?(texts, &(&1 == text or first_line(&1) == text)) ->
        texts

      first_line(text) in texts ->
        Enum.map(texts, &if(&1 == first_line(text), do: text, else: &1))

      true ->
        texts ++ [text]
    end
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

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
end
