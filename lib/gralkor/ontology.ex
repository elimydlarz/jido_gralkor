defmodule Gralkor.Ontology do
  @moduledoc """
  Declare an entity-and-relationship ontology for graphiti's custom entity
  extraction.

  A consumer writes:

      defmodule MyOntology do
        use Gralkor.Ontology, entities: :strict, relationships: :scoped

        entity User do
          field :handle,   :string, required: true, doc: "stable login handle"
          field :timezone, :string,                  doc: "IANA tz"
        end

        entity Preference do
          field :description, :string, required: true
        end

        from User do
          prefers Preference do
            field :since, :string, doc: "date first observed"
          end
          trusts User
        end
      end

  The macro produces `MyOntology.__ontology__/0` — a payload the Pythonx
  layer translates into graphiti's `entity_types`, `edge_types`,
  `edge_type_map`, and `excluded_entity_types`. The Elixir side never
  constructs Pydantic classes.

  See `ex-ontology` and `ex-ontology-payload` in `TEST_TREES.md`.
  """

  @allowed_entities [:strict, :open]
  @allowed_relationships [:scoped, :open]
  @allowed_field_types [:string, :integer, :float, :boolean]

  defmacro __using__(opts) do
    entities = fetch_use_opt!(opts, :entities, @allowed_entities)
    relationships = fetch_use_opt!(opts, :relationships, @allowed_relationships)

    quote do
      import Gralkor.Ontology, only: [entity: 2, from: 2]

      Module.register_attribute(__MODULE__, :gralkor_ontology_entities, accumulate: true)
      Module.register_attribute(__MODULE__, :gralkor_ontology_edges, accumulate: true)

      @gralkor_ontology_use_opts %{
        entities: unquote(entities),
        relationships: unquote(relationships)
      }

      @before_compile Gralkor.Ontology
    end
  end

  defmacro entity({:__aliases__, _, segments}, do: block) do
    name = segments |> List.last() |> Atom.to_string()

    quote do
      Module.put_attribute(
        __MODULE__,
        :gralkor_ontology_current_entity,
        {unquote(name), []}
      )

      try do
        import Gralkor.Ontology, only: [field: 2, field: 3]
        unquote(block)
      after
        :ok
      end

      {name, fields} = Module.delete_attribute(__MODULE__, :gralkor_ontology_current_entity)
      Module.put_attribute(__MODULE__, :gralkor_ontology_entities, {name, Enum.reverse(fields)})
    end
  end

  defmacro entity(other, _opts) do
    raise CompileError,
      description:
        "Gralkor.Ontology: `entity` requires an alias (e.g. `entity User do … end`); got #{Macro.to_string(other)}"
  end

  defmacro field(name, type, opts \\ []) when is_atom(name) and is_atom(type) do
    unless type in @allowed_field_types do
      raise CompileError,
        description:
          "Gralkor.Ontology: field type #{inspect(type)} is not supported (allowed: #{inspect(@allowed_field_types)})"
    end

    required = Keyword.get(opts, :required, false)
    doc = Keyword.get(opts, :doc)

    entry =
      Macro.escape(%{name: name, type: type, required: required, doc: doc})

    quote do
      Gralkor.Ontology.__add_field__(__MODULE__, unquote(entry))
    end
  end

  defmacro from({:__aliases__, _, segments}, do: block) do
    source = segments |> List.last() |> Atom.to_string()

    quote do
      Module.put_attribute(__MODULE__, :gralkor_ontology_current_source, unquote(source))

      try do
        import Gralkor.Ontology, only: [from_verb_call: 2, from_verb_call: 3]

        unquote(rewrite_from_block(block))
      after
        Module.delete_attribute(__MODULE__, :gralkor_ontology_current_source)
      end
    end
  end

  defmacro from(other, _opts) do
    raise CompileError,
      description:
        "Gralkor.Ontology: `from` requires an alias (e.g. `from User do … end`); got #{Macro.to_string(other)}"
  end

  defp rewrite_from_block({:__block__, meta, lines}) do
    {:__block__, meta, Enum.map(lines, &rewrite_from_line/1)}
  end

  defp rewrite_from_block(line), do: rewrite_from_line(line)

  defp rewrite_from_line({verb, _meta, [{:__aliases__, _, segments}]}) when is_atom(verb) do
    target = segments |> List.last() |> Atom.to_string()
    quote do: from_verb_call(unquote(verb), unquote(target))
  end

  defp rewrite_from_line({verb, _meta, [{:__aliases__, _, segments}, [do: block]]})
       when is_atom(verb) do
    target = segments |> List.last() |> Atom.to_string()
    quote do: from_verb_call(unquote(verb), unquote(target), do: unquote(block))
  end

  defp rewrite_from_line(other) do
    raise CompileError,
      description:
        "Gralkor.Ontology: inside `from`, expected `verb Target` or `verb Target do … end`; got #{Macro.to_string(other)}"
  end

  defmacro from_verb_call(verb, target) when is_atom(verb) and is_binary(target) do
    edge_name = verb_to_edge_name(verb)

    quote do
      Gralkor.Ontology.__add_edge__(
        __MODULE__,
        unquote(edge_name),
        Module.get_attribute(__MODULE__, :gralkor_ontology_current_source),
        unquote(target),
        []
      )
    end
  end

  defmacro from_verb_call(verb, target, do: block) when is_atom(verb) and is_binary(target) do
    edge_name = verb_to_edge_name(verb)

    quote do
      Module.put_attribute(
        __MODULE__,
        :gralkor_ontology_current_edge_fields,
        []
      )

      try do
        import Gralkor.Ontology, only: [field: 2, field: 3]
        unquote(block)
      after
        :ok
      end

      fields =
        __MODULE__
        |> Module.delete_attribute(:gralkor_ontology_current_edge_fields)
        |> Enum.reverse()

      Gralkor.Ontology.__add_edge__(
        __MODULE__,
        unquote(edge_name),
        Module.get_attribute(__MODULE__, :gralkor_ontology_current_source),
        unquote(target),
        fields
      )
    end
  end

  @doc false
  def __add_field__(module, field) do
    case Module.get_attribute(module, :gralkor_ontology_current_edge_fields) do
      nil ->
        case Module.get_attribute(module, :gralkor_ontology_current_entity) do
          nil ->
            raise CompileError,
              description:
                "Gralkor.Ontology: `field` may only be used inside `entity` or relationship blocks"

          {name, existing} ->
            ensure_unique_field!(existing, field, "entity #{inspect(name)}")

            Module.put_attribute(
              module,
              :gralkor_ontology_current_entity,
              {name, [field | existing]}
            )
        end

      existing ->
        ensure_unique_field!(existing, field, "edge")
        Module.put_attribute(module, :gralkor_ontology_current_edge_fields, [field | existing])
    end
  end

  @doc false
  def __add_edge__(module, edge_name, source, target, fields) do
    Module.put_attribute(
      module,
      :gralkor_ontology_edges,
      %{name: edge_name, source: source, target: target, fields: fields}
    )
  end

  defmacro __before_compile__(env) do
    entities =
      env.module
      |> Module.get_attribute(:gralkor_ontology_entities)
      |> Enum.reverse()

    edges =
      env.module
      |> Module.get_attribute(:gralkor_ontology_edges)
      |> Enum.reverse()

    use_opts = Module.get_attribute(env.module, :gralkor_ontology_use_opts)

    payload = build_payload(env.module, entities, edges, use_opts)

    quote do
      def __ontology__, do: unquote(Macro.escape(payload))
    end
  end

  defp build_payload(module, entities, edges, use_opts) do
    ensure_unique_entities!(module, entities)
    entity_payloads = Enum.map(entities, fn {name, fields} -> %{name: name, fields: fields} end)
    entity_names = MapSet.new(entity_payloads, & &1.name)

    ensure_known_endpoints!(module, edges, entity_names)
    edge_types = build_edge_types(module, edges)
    edge_type_map = build_edge_type_map(edges, use_opts.relationships)

    excluded_entity_types =
      case use_opts.entities do
        :strict -> ["Entity"]
        :open -> nil
      end

    %{
      entity_types: entity_payloads,
      edge_types: edge_types,
      edge_type_map: edge_type_map,
      excluded_entity_types: excluded_entity_types
    }
  end

  defp ensure_unique_entities!(module, entities) do
    entities
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.frequencies()
    |> Enum.find(fn {_, count} -> count > 1 end)
    |> case do
      nil ->
        :ok

      {name, _} ->
        raise CompileError,
          description:
            "Gralkor.Ontology: entity #{inspect(name)} is declared more than once in #{inspect(module)}"
    end
  end

  defp ensure_known_endpoints!(module, edges, entity_names) do
    Enum.each(edges, fn %{name: edge, source: src, target: tgt} ->
      unless MapSet.member?(entity_names, src) do
        raise CompileError,
          description:
            "Gralkor.Ontology: `from #{src}` in #{inspect(module)} references unknown entity #{inspect(src)} (declared edge #{inspect(edge)})"
      end

      unless MapSet.member?(entity_names, tgt) do
        raise CompileError,
          description:
            "Gralkor.Ontology: edge #{inspect(edge)} in #{inspect(module)} targets unknown entity #{inspect(tgt)}"
      end
    end)
  end

  defp build_edge_types(module, edges) do
    edges
    |> Enum.reduce({[], %{}}, fn %{name: name, fields: fields}, {ordered, seen} ->
      case Map.fetch(seen, name) do
        :error ->
          payload = %{name: name, fields: fields}
          {[payload | ordered], Map.put(seen, name, fields)}

        {:ok, existing_fields} ->
          unless fields_equivalent?(existing_fields, fields) do
            raise CompileError,
              description:
                "Gralkor.Ontology: edge #{inspect(name)} in #{inspect(module)} is declared with conflicting field schemas — every `from` block declaring the same verb must agree on edge properties"
          end

          {ordered, seen}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp build_edge_type_map(_edges, :open), do: []

  defp build_edge_type_map(edges, :scoped) do
    edges
    |> Enum.reduce({[], %{}}, fn %{name: edge, source: src, target: tgt}, {ordered, seen} ->
      key = {src, tgt}

      case Map.fetch(seen, key) do
        :error ->
          {[{key, [edge]} | ordered], Map.put(seen, key, [edge])}

        {:ok, names} ->
          if edge in names do
            {ordered, seen}
          else
            updated = names ++ [edge]
            ordered = update_first_match(ordered, key, updated)
            {ordered, Map.put(seen, key, updated)}
          end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp update_first_match([{key, _old} | rest], key, new), do: [{key, new} | rest]

  defp update_first_match([head | rest], key, new),
    do: [head | update_first_match(rest, key, new)]

  defp update_first_match([], _key, _new), do: []

  defp fields_equivalent?(a, b) do
    normalise = fn fields ->
      fields
      |> Enum.map(fn %{name: name, type: type, required: required} ->
        {name, type, required}
      end)
      |> Enum.sort()
    end

    normalise.(a) == normalise.(b)
  end

  defp ensure_unique_field!(existing, %{name: name}, location) do
    if Enum.any?(existing, &(&1.name == name)) do
      raise CompileError,
        description:
          "Gralkor.Ontology: field #{inspect(name)} is declared more than once in #{location}"
    end
  end

  defp verb_to_edge_name(verb) when is_atom(verb) do
    verb |> Atom.to_string() |> String.upcase()
  end

  defp fetch_use_opt!(opts, key, allowed) do
    case Keyword.fetch(opts, key) do
      :error ->
        raise CompileError,
          description:
            "Gralkor.Ontology: missing required option #{inspect(key)} (allowed values: #{inspect(allowed)})"

      {:ok, value} when is_atom(value) ->
        if value in allowed do
          value
        else
          raise CompileError,
            description:
              "Gralkor.Ontology: invalid value #{inspect(value)} for #{inspect(key)} (allowed: #{inspect(allowed)})"
        end

      {:ok, other} ->
        raise CompileError,
          description:
            "Gralkor.Ontology: #{inspect(key)} must be one of #{inspect(allowed)}; got #{inspect(other)}"
    end
  end
end
