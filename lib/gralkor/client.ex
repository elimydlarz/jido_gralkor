defmodule Gralkor.Client do
  @moduledoc """
  Public entry point and adapter port for Gralkor memory.

  Named Lens operations use `ingest/1` and `replace/1`; `search/1` reads
  registered Destinations and may filter episode writers by Lens.
  Ingestion resolves an appending Lens and invokes its ingestion process with a
  Lens-bound store. Replacement validates and stores the complete graph for a
  replaceable Lens. Lenses and Reflections reference first-class Destinations,
  each of which names one graph. Appending Lenses select the ontology for their
  writes; Reflection Destination outputs select it for runtime-delivered
  artefacts. The runtime-targeted arities resolve names from one consuming
  AgentServer's atomic configuration snapshot. `reflect/5` admits an invocation
  without waiting for production and reports its terminal result through the
  supplied callback. With empty selectors, search runs every
  accessible registered Destination concurrently and returns episodes from
  every Lens and Reflection writer. Destination and Lens names are ORed within
  their respective selectors and ANDed across them; Lens filters are
  episode-only. Each result identifies its Destination, while each episode
  identifies its originating Lens or Reflection and Lens episodes retain their
  source description. Facts, nodes, and Reflection artefacts are explicit
  advanced result types.

  The compatibility surface remains `recall/4`, `capture/5`, `flush/1`,
  `flush_and_await/2`, and `memory_add/3` or `/4`. Lens-aware capture uses
  `capture/6`, or `capture/7` when the same turn is also routed through
  additional Lenses. Logical graph IDs are encoded exactly once at the physical graph boundary as `g_` plus the
  lowercase hexadecimal encoding of every original byte (`sanitize_group_id/1`).
  The `operator` Destination resolves to `operator/<operator id>`, so search
  reads only the current operator's operator graph; every other Destination
  resolves to its exact shared name.

  `flush/1` returns `:ok` before the buffered turns have landed
  (fire-and-forget — appropriate for shutdown paths that cannot block).
  `flush_and_await/2` returns `:ok` only after buffered ingestion completes,
  for callers that must observe completion before rotating state (for example
  session-id rotation in `JidoGralkor.ContextRotator`).

  The concrete adapter is resolved from `Application.get_env(:jido_gralkor, :client)`;
  defaults to `Gralkor.Client.Native` (in-process via Pythonx). Tests swap in
  `Gralkor.Client.InMemory`.

  No `health_check/0` — the embedded runtime is ready by the time
  `Application.start/2` returns; runtime failures surface from the next call.
  """

  @type group_id :: String.t()
  @type session_id :: String.t()
  @type agent_name :: String.t()
  @type messages :: [Gralkor.Message.t()]
  @type user_name :: String.t()
  @type search_result :: map()

  alias Gralkor.Ingest
  alias Gralkor.IngestedRepresentation
  alias Gralkor.Destination.Registry, as: DestinationRegistry
  alias Gralkor.Lens
  alias Gralkor.Lens.Ingestion.Store, as: StoreIngestion
  alias Gralkor.Lens.Replaceable, as: ReplaceableLens
  alias Gralkor.Lens.Store
  alias Gralkor.Replace
  alias Gralkor.Destination.Storage, as: DestinationStorage
  alias Gralkor.Search
  alias JidoGralkor.Runtime

  @callback recall(group_id(), agent_name(), session_id() | nil, query :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback capture(
              session_id(),
              group_id(),
              agent_name(),
              user_name(),
              messages()
            ) ::
              :ok | {:error, term()}
  @callback capture(
              session_id(),
              group_id(),
              agent_name(),
              user_name(),
              messages(),
              lens :: String.t(),
              additional_lenses :: [String.t()]
            ) ::
              :ok | {:error, term()}
  @callback capture(
              session_id(),
              group_id(),
              agent_name(),
              user_name(),
              messages(),
              lens :: String.t()
            ) ::
              :ok | {:error, term()}
  @callback memory_add(
              group_id(),
              content :: String.t(),
              source_description :: String.t() | nil
            ) ::
              :ok | {:error, term()}
  @callback memory_add(
              group_id(),
              content :: String.t() | map() | list(),
              source_description :: String.t() | nil,
              source_kind :: Ingest.source_kind()
            ) ::
              :ok | {:error, term()}
  @callback flush(session_id()) :: :ok | {:error, term()}
  @callback flush_and_await(session_id(), timeout_ms :: pos_integer()) ::
              :ok | {:error, :timeout} | {:error, term()}
  @callback build_indices() :: {:ok, %{status: String.t()}} | {:error, term()}
  @callback build_communities(group_id()) ::
              {:ok, %{communities: non_neg_integer(), edges: non_neg_integer()}}
              | {:error, term()}
  @spec impl() :: module()
  def impl, do: Application.get_env(:jido_gralkor, :client, Gralkor.Client.Native)

  @spec ingest(Ingest.t()) :: :ok | {:error, term()}
  def ingest(%Ingest{} = request) do
    case ingest_with_representation(request) do
      {:ok, _representations} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @spec ingest(GenServer.server(), Ingest.t()) :: :ok | {:error, term()}
  def ingest(runtime_owner, %Ingest{} = request) do
    case ingest_with_representation(runtime_owner, request) do
      {:ok, _representations} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @spec reflect(GenServer.server(), String.t(), map(), (term() -> any()), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def reflect(runtime_owner, reflection_name, invocation, callback, opts \\ []) do
    Runtime.submit_reflection(runtime_owner, reflection_name, invocation, callback, opts)
  end

  @doc false
  def capture(
        runtime_owner,
        session_id,
        operator_id,
        agent_name,
        user_name,
        messages,
        lens,
        additional_lenses
      ) do
    client = impl()

    if Code.ensure_loaded?(client) and function_exported?(client, :capture, 8) do
      client.capture(
        runtime_owner,
        session_id,
        operator_id,
        agent_name,
        user_name,
        messages,
        lens,
        additional_lenses
      )
    else
      client.capture(
        session_id,
        operator_id,
        agent_name,
        user_name,
        messages,
        lens,
        additional_lenses
      )
    end
  end

  @doc false
  @spec ingest_with_representation(Ingest.t()) ::
          {:ok, [IngestedRepresentation.t()]} | {:error, term()}
  def ingest_with_representation(%Ingest{lens: lens_name} = request) do
    ingest_with_resolved_lens(request, lens!(lens_name))
  end

  @doc false
  @spec ingest_with_representation(GenServer.server(), Ingest.t()) ::
          {:ok, [IngestedRepresentation.t()]} | {:error, term()}
  def ingest_with_representation(runtime_owner, %Ingest{lens: lens_name} = request) do
    ingest_with_resolved_lens(request, Runtime.lens!(runtime_owner, lens_name))
  end

  defp ingest_with_resolved_lens(request, lens) do
    Ingest.validate_operator_id!(request.operator_id)
    Ingest.validate_id!(request.id)
    Ingest.validate_source!(request.source_kind, request.content)

    case lens do
      %Lens{} = lens ->
        collection_ref = make_ref()
        caller = self()

        store = %Store{
          operator_id: request.operator_id,
          lens: lens,
          source_kind: request.source_kind,
          representation_collector: &send(caller, {collection_ref, &1})
        }

        case lens.ingestion.ingest(request, store) do
          :ok ->
            {:ok, collect_representations(collection_ref, [])}

          {:error, _} = error ->
            _discarded = collect_representations(collection_ref, [])
            error
        end

      %ReplaceableLens{} ->
        raise ArgumentError,
              "Lens #{inspect(request.lens)} accepts only whole-graph replacement"
    end
  end

  defp collect_representations(collection_ref, representations) do
    receive do
      {^collection_ref, %IngestedRepresentation{} = representation} ->
        collect_representations(collection_ref, [representation | representations])
    after
      0 -> Enum.reverse(representations)
    end
  end

  @spec replace(Replace.t()) :: :ok | {:error, term()}
  def replace(%Replace{lens: lens_name, graph: graph} = request) do
    replace_with_resolved_lens(request, graph, lens!(lens_name))
  end

  @spec replace(GenServer.server(), Replace.t()) :: :ok | {:error, term()}
  def replace(runtime_owner, %Replace{lens: lens_name, graph: graph} = request) do
    replace_with_resolved_lens(request, graph, Runtime.lens!(runtime_owner, lens_name))
  end

  defp replace_with_resolved_lens(request, graph, lens) do
    case lens do
      %ReplaceableLens{} = lens ->
        validate_graph!(lens, graph)
        store = %Store{operator_id: request.operator_id, lens: lens}
        Store.replace_graph(store, graph)

      %Lens{} ->
        raise ArgumentError, "Lens #{inspect(request.lens)} accepts only episode ingestion"
    end
  end

  defp validate_graph!(%ReplaceableLens{}, %Gralkor.Graph{} = graph) do
    validate_graph_data!(graph)
  end

  defp validate_graph_data!(%Gralkor.Graph{nodes: nodes, relationships: relationships} = graph)
       when is_list(nodes) and is_list(relationships) do
    node_ids = validate_graph_nodes!(nodes, graph)
    validate_graph_relationships!(relationships, node_ids, graph)
  end

  defp validate_graph_data!(graph),
    do: invalid_graph!("expected node and relationship lists", graph)

  defp validate_graph_nodes!(nodes, graph) do
    Enum.reduce(nodes, MapSet.new(), fn node, node_ids ->
      case node do
        %{id: id, labels: labels, properties: properties}
        when is_binary(id) and is_list(labels) and is_map(properties) ->
          unless String.trim(id) != "" and
                   Enum.all?(labels, &(is_binary(&1) and String.trim(&1) != "")) do
            invalid_graph!("invalid node", graph)
          end

          if MapSet.member?(node_ids, id) do
            invalid_graph!("duplicate node identifier #{inspect(id)}", graph)
          end

          MapSet.put(node_ids, id)

        _ ->
          invalid_graph!("invalid node", graph)
      end
    end)
  end

  defp validate_graph_relationships!(relationships, node_ids, graph) do
    Enum.each(relationships, fn relationship ->
      case relationship do
        %{from: source, to: destination, type: type, properties: properties}
        when is_binary(source) and is_binary(destination) and is_binary(type) and
               is_map(properties) ->
          unless String.trim(type) != "" do
            invalid_graph!("invalid relationship", graph)
          end

          Enum.each([source, destination], fn endpoint ->
            unless MapSet.member?(node_ids, endpoint) do
              invalid_graph!("missing relationship endpoint #{inspect(endpoint)}", graph)
            end
          end)

        _ ->
          invalid_graph!("invalid relationship", graph)
      end
    end)
  end

  defp invalid_graph!(reason, graph) do
    raise ArgumentError, "invalid graph data: #{reason}; got #{inspect(graph)}"
  end

  @spec search(Search.t()) ::
          {:ok, [search_result()]} | {:error, term()}
  def search(%Search{} = request) do
    _ = registered_lenses!()
    validate_max_results!(request.max_results)
    validate_result_type!(request.result_type)

    lenses = resolve_search_lenses!(request.lenses)
    validate_lens_result_type!(lenses, request.result_type)

    destinations = resolve_search_destinations!(request.destinations)
    search_resolved(request, lenses, destinations)
  end

  @spec search(GenServer.server(), Search.t()) ::
          {:ok, [search_result()]} | {:error, term()}
  def search(runtime_owner, %Search{} = request) do
    validate_max_results!(request.max_results)
    validate_result_type!(request.result_type)

    lenses = resolve_search_lenses!(runtime_owner, request.lenses)
    validate_lens_result_type!(lenses, request.result_type)

    destinations = resolve_search_destinations!(runtime_owner, request.destinations)
    search_resolved(request, lenses, destinations)
  end

  defp search_resolved(request, lenses, destinations) do
    opts =
      []
      |> put_search_option(:entity_types, request.entity_types)
      |> put_search_option(:edge_types, request.edge_types)
      |> put_search_option(:artefact_id, request.artefact_id)
      |> put_search_option(:lenses, lenses)

    destinations
    |> Enum.map(fn destination ->
      Task.async(fn ->
        {destination.name,
         DestinationStorage.search(
           destination,
           request.operator_id,
           request.query,
           request.result_type,
           request.max_results,
           opts
         )}
      end)
    end)
    |> Task.await_many(:infinity)
    |> Enum.reduce_while({:ok, []}, fn search_result, {:ok, results} ->
      case search_result do
        {destination_name, {:ok, destination_results}} ->
          attributed =
            Enum.map(
              destination_results,
              &attribute_result(destination_name, request.result_type, &1)
            )

          {:cont, {:ok, results ++ attributed}}

        {_destination_name, {:error, _reason} = error} ->
          {:halt, error}
      end
    end)
  end

  defp attribute_result(destination, :facts, fact), do: %{destination: destination, fact: fact}
  defp attribute_result(destination, :nodes, node), do: %{destination: destination, node: node}

  defp attribute_result(destination, :episodes, episode),
    do: %{destination: destination, episode: episode}

  defp attribute_result(destination, :artefacts, artefact),
    do: %{destination: destination, artefact: artefact}

  defp put_search_option(opts, _key, []), do: opts
  defp put_search_option(opts, _key, nil), do: opts
  defp put_search_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp validate_result_type!(type) when type in [:facts, :nodes, :episodes, :artefacts], do: :ok

  defp validate_result_type!(type),
    do: raise(ArgumentError, "unsupported search result type #{inspect(type)}")

  defp resolve_search_destinations!([]), do: DestinationRegistry.configured!()

  defp resolve_search_destinations!(names) when is_list(names) do
    names
    |> Enum.map(fn
      name when is_binary(name) ->
        if String.trim(name) == "" do
          raise ArgumentError, "invalid Destination name #{inspect(name)}"
        end

        DestinationRegistry.fetch!(name)

      name ->
        raise ArgumentError, "invalid Destination name #{inspect(name)}"
    end)
    |> Enum.uniq_by(& &1.name)
  end

  defp resolve_search_destinations!(names),
    do: raise(ArgumentError, "search destinations must be a list, got #{inspect(names)}")

  defp resolve_search_destinations!(runtime_owner, []), do: Runtime.destinations(runtime_owner)

  defp resolve_search_destinations!(runtime_owner, names) when is_list(names) do
    names
    |> Enum.map(fn
      name when is_binary(name) ->
        if String.trim(name) == "" do
          raise ArgumentError, "invalid Destination name #{inspect(name)}"
        end

        Runtime.destination!(runtime_owner, name)

      name ->
        raise ArgumentError, "invalid Destination name #{inspect(name)}"
    end)
    |> Enum.uniq_by(& &1.name)
  end

  defp resolve_search_destinations!(_runtime_owner, names),
    do: raise(ArgumentError, "search destinations must be a list, got #{inspect(names)}")

  defp resolve_search_lenses!(names) when is_list(names) do
    names
    |> Enum.map(fn
      name when is_binary(name) ->
        if String.trim(name) == "" do
          raise ArgumentError, "invalid Lens name #{inspect(name)}"
        end

        lens!(name).name

      name ->
        raise ArgumentError, "invalid Lens name #{inspect(name)}"
    end)
    |> Enum.uniq()
  end

  defp resolve_search_lenses!(names),
    do: raise(ArgumentError, "search lenses must be a list, got #{inspect(names)}")

  defp resolve_search_lenses!(runtime_owner, names) when is_list(names) do
    names
    |> Enum.map(fn
      name when is_binary(name) ->
        if String.trim(name) == "" do
          raise ArgumentError, "invalid Lens name #{inspect(name)}"
        end

        Runtime.lens!(runtime_owner, name).name

      name ->
        raise ArgumentError, "invalid Lens name #{inspect(name)}"
    end)
    |> Enum.uniq()
  end

  defp resolve_search_lenses!(_runtime_owner, names),
    do: raise(ArgumentError, "search lenses must be a list, got #{inspect(names)}")

  defp validate_lens_result_type!([], _result_type), do: :ok
  defp validate_lens_result_type!(_lenses, :episodes), do: :ok

  defp validate_lens_result_type!(_lenses, result_type) do
    raise ArgumentError,
          "Lens selection requires episode results, got #{inspect(result_type)}"
  end

  @spec validate_max_results!(term()) :: :ok
  defp validate_max_results!(max_results) when is_integer(max_results) and max_results > 0,
    do: :ok

  defp validate_max_results!(max_results) do
    raise ArgumentError,
          "max_results must be a positive integer, got #{inspect(max_results)}"
  end

  @spec lens!(String.t()) :: Lens.t() | ReplaceableLens.t()
  def lens!(name) do
    lenses = registered_lenses!()

    case Enum.find(lenses, fn definition -> Keyword.get(definition, :name) == name end) do
      nil when name == "operator" ->
        %Lens{
          name: "operator",
          destination: DestinationRegistry.fetch!("operator"),
          ontology: Gralkor.DefaultOntology,
          ingestion: StoreIngestion
        }

      nil when name == "default" ->
        raise ArgumentError,
              "Lens \"default\" was retired; use the reserved \"operator\" Lens instead"

      nil ->
        raise ArgumentError, "unknown Lens #{inspect(name)}"

      definition ->
        resolve_lens(definition)
    end
  end

  defp resolve_lens(definition) do
    case Keyword.get(definition, :write, :append) do
      :append ->
        %Lens{
          name: Keyword.fetch!(definition, :name),
          destination:
            fetch_lens_destination!(
              Keyword.fetch!(definition, :name),
              Keyword.get(definition, :destination)
            ),
          ontology: Keyword.get(definition, :ontology, Gralkor.DefaultOntology),
          ingestion: Keyword.fetch!(definition, :ingestion)
        }

      :replace_graph ->
        %ReplaceableLens{
          name: Keyword.fetch!(definition, :name),
          destination:
            fetch_lens_destination!(
              Keyword.fetch!(definition, :name),
              Keyword.get(definition, :destination)
            )
        }
    end
  end

  defp registered_lenses! do
    case Application.get_env(:jido_gralkor, :lenses, []) do
      lenses when is_list(lenses) ->
        Enum.each(lenses, &validate_lens!/1)
        validate_unique_names!(lenses)
        lenses

      lenses ->
        raise ArgumentError, "Lens registry must be a list, got #{inspect(lenses)}"
    end
  end

  defp validate_lens!(definition) when is_list(definition) do
    unless Keyword.keyword?(definition) do
      raise ArgumentError, "invalid Lens definition #{inspect(definition)}"
    end

    name = Keyword.get(definition, :name)

    unless is_binary(name) and String.trim(name) != "" do
      raise ArgumentError, "invalid Lens name #{inspect(name)}"
    end

    if String.contains?(name, " [lens: ") do
      raise ArgumentError,
            "invalid Lens #{inspect(name)}: name contains reserved provenance syntax \" [lens: \""
    end

    if name == "default" do
      raise ArgumentError,
            "invalid Lens \"default\": name was retired; use \"operator\" instead"
    end

    if name in ["operator", "global"] do
      raise ArgumentError, "invalid Lens #{inspect(name)}: name is reserved"
    end

    if Keyword.has_key?(definition, :scope) or Keyword.has_key?(definition, :address) do
      raise ArgumentError, "invalid Lens #{inspect(name)}: scope and address are unsupported"
    end

    if Keyword.has_key?(definition, :graph_format) do
      raise ArgumentError,
            "invalid Lens #{inspect(name)}: graph_format is unsupported; Gralkor has one fixed graph representation"
    end

    validate_lens_write!(name, definition)
  end

  defp validate_lens!(definition) do
    raise ArgumentError, "invalid Lens definition #{inspect(definition)}"
  end

  defp validate_lens_write!(name, definition) do
    case Keyword.get(definition, :write, :append) do
      :append ->
        destination = Keyword.get(definition, :destination)
        ontology = Keyword.get(definition, :ontology, Gralkor.DefaultOntology)
        ingestion = Keyword.get(definition, :ingestion)

        fetch_lens_destination!(name, destination)
        validate_lens_ontology!(name, ontology)

        unless is_atom(ingestion) and Code.ensure_loaded?(ingestion) and
                 function_exported?(ingestion, :ingest, 2) do
          raise ArgumentError, "invalid Lens #{inspect(name)} ingestion #{inspect(ingestion)}"
        end

      :replace_graph ->
        fetch_lens_destination!(name, Keyword.get(definition, :destination))

        if Keyword.has_key?(definition, :ontology) or Keyword.has_key?(definition, :ingestion) do
          raise ArgumentError,
                "invalid Lens #{inspect(name)} combines appending and replaceable write settings"
        end

      write ->
        raise ArgumentError, "invalid Lens #{inspect(name)} write mode #{inspect(write)}"
    end
  end

  defp validate_unique_names!(lenses) do
    lenses
    |> Enum.group_by(&Keyword.get(&1, :name))
    |> Enum.find(fn {_name, definitions} -> length(definitions) > 1 end)
    |> case do
      nil -> :ok
      {name, _definitions} -> raise ArgumentError, "duplicate Lens #{inspect(name)}"
    end
  end

  defp fetch_lens_destination!(lens_name, destination_name) do
    unless is_binary(destination_name) and String.trim(destination_name) != "" do
      raise ArgumentError,
            "invalid Lens #{inspect(lens_name)} Destination #{inspect(destination_name)}"
    end

    DestinationRegistry.fetch!(destination_name)
  rescue
    error in ArgumentError ->
      raise ArgumentError,
            "invalid Lens #{inspect(lens_name)} Destination #{inspect(destination_name)}: #{Exception.message(error)}"
  end

  defp validate_lens_ontology!(name, ontology) do
    unless is_atom(ontology) and Code.ensure_loaded?(ontology) and
             function_exported?(ontology, :__ontology__, 0) do
      raise ArgumentError, "invalid Lens #{inspect(name)} ontology #{inspect(ontology)}"
    end
  end

  @doc false
  @spec operator_graph_id(String.t()) :: String.t()
  def operator_graph_id(operator_id) when is_binary(operator_id) do
    DestinationRegistry.fetch!("operator")
    |> Gralkor.Destination.graph_id(operator_id)
  end

  @spec sanitize_group_id(String.t()) :: String.t()
  def sanitize_group_id(id) when is_binary(id) do
    "g_" <> Base.encode16(id, case: :lower)
  end
end
