defmodule Gralkor.Client do
  @moduledoc """
  Public entry point and adapter port for Gralkor memory.

  Named Lens operations use `ingest/1`, `replace/1`, and `search/1`. Ingestion
  resolves an appending Lens and invokes its ingestion process with a
  Lens-bound store. Replacement validates and stores the complete graph for a
  replaceable Lens. Lens search includes the requesting operator's reserved
  `"operator"` Lens and searches every distinct selected destination
  concurrently. Reflection search is a separate namespace: it resolves named
  Reflections to their own operator or global destinations and returns
  artefacts attributed to those Reflections. Every Lens resolves to the group
  its content lives in, so all selected global Lens names collapse to one
  shared `"global"` search.

  The compatibility surface remains `recall/4`, `capture/5`, `flush/1`,
  `flush_and_await/2`, and `memory_add/3` or `/4`. Lens-aware capture uses
  `capture/6`, or `capture/7` when the same turn is also routed through
  additional Lenses. The internal `capture/8` form also carries the host tools
  and tool context made available to subsequent Reflections. Legacy group IDs
  are sanitised at their graph boundary (`sanitize_group_id/1`); Lens storage
  binds the original operator id to its selected Lens instead.

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

  require Logger

  @type group_id :: String.t()
  @type session_id :: String.t()
  @type agent_name :: String.t()
  @type messages :: [Gralkor.Message.t()]
  @type user_name :: String.t()
  @type search_result :: %{lens: String.t(), fact: String.t()}
  @type reflection_search_result :: Gralkor.Reflection.Artefact.t()
  @type search_target :: %{
          destination: :global | {:operator, String.t(), String.t()},
          lens: String.t(),
          store: Store.t()
        }

  alias Gralkor.Ingest
  alias Gralkor.IngestedRepresentation
  alias Gralkor.Destination.Registry, as: DestinationRegistry
  alias Gralkor.Lens
  alias Gralkor.Lens.Ingestion.Store, as: StoreIngestion
  alias Gralkor.Lens.Replaceable, as: ReplaceableLens
  alias Gralkor.Lens.Store
  alias Gralkor.Replace
  alias Gralkor.Reflection.Registry, as: ReflectionRegistry
  alias Gralkor.Reflection.Scheduler, as: ReflectionScheduler
  alias Gralkor.Reflection.Store, as: ReflectionStore
  alias Gralkor.Search

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
              additional_lenses :: [String.t()],
              reflection_context :: map()
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
      {:ok, representations} when is_list(representations) ->
        schedule_direct_reflections(request, representations)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc false
  @spec ingest_with_representation(Ingest.t()) ::
          {:ok, [IngestedRepresentation.t()]} | {:error, term()}
  def ingest_with_representation(%Ingest{lens: lens_name} = request) do
    case lens!(lens_name) do
      %Lens{} = lens ->
        collection_ref = make_ref()
        caller = self()

        store = %Store{
          operator_id: request.operator_id,
          lens: lens,
          evidence_id: request.evidence_id || IngestedRepresentation.new_evidence_id(),
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
              "Lens #{inspect(lens_name)} accepts only whole-graph replacement"
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

  defp schedule_direct_reflections(_request, []), do: :ok

  defp schedule_direct_reflections(request, representations) do
    if Process.whereis(ReflectionScheduler) do
      evidence_id = hd(representations).evidence_id

      ingestion = %{
        id: "direct:#{evidence_id}:#{System.unique_integer([:positive, :monotonic])}",
        operator_id: request.operator_id,
        intended_lenses: [request.lens],
        completed_lenses: [request.lens],
        representations: representations
      }

      case ReflectionScheduler.schedule(ReflectionRegistry.configured!(), ingestion) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[gralkor] direct-ingestion Reflection scheduling failed — #{inspect(reason)}"
          )
      end
    end
  rescue
    exception ->
      Logger.warning(
        "[gralkor] direct-ingestion Reflection scheduling raised — " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  end

  @spec replace(Replace.t()) :: :ok | {:error, term()}
  def replace(%Replace{lens: lens_name, graph: graph} = request) do
    case lens!(lens_name) do
      %ReplaceableLens{} = lens ->
        validate_graph!(lens, graph)
        store = %Store{operator_id: request.operator_id, lens: lens}
        Store.replace_graph(store, graph)

      %Lens{} ->
        raise ArgumentError, "Lens #{inspect(lens_name)} accepts only episode ingestion"
    end
  end

  defp validate_graph!(
         %ReplaceableLens{graph_format: expected},
         %Gralkor.Graph{format: supplied}
       )
       when expected != supplied do
    raise ArgumentError,
          "Lens graph format mismatch: expected #{inspect(expected)}, supplied #{inspect(supplied)}"
  end

  defp validate_graph!(%ReplaceableLens{graph_format: :property_graph}, %Gralkor.Graph{
         data: data
       }) do
    validate_property_graph!(data)
  end

  defp validate_property_graph!(%{nodes: nodes, relationships: relationships} = data)
       when is_list(nodes) and is_list(relationships) do
    node_ids = validate_property_graph_nodes!(nodes, data)
    validate_property_graph_relationships!(relationships, node_ids, data)
  end

  defp validate_property_graph!(data),
    do: invalid_property_graph!("expected node and relationship lists", data)

  defp validate_property_graph_nodes!(nodes, data) do
    Enum.reduce(nodes, MapSet.new(), fn node, node_ids ->
      case node do
        %{id: id, labels: labels, properties: properties}
        when is_binary(id) and is_list(labels) and is_map(properties) ->
          unless String.trim(id) != "" and
                   Enum.all?(labels, &(is_binary(&1) and String.trim(&1) != "")) do
            invalid_property_graph!("invalid node", data)
          end

          if MapSet.member?(node_ids, id) do
            invalid_property_graph!("duplicate node identifier #{inspect(id)}", data)
          end

          MapSet.put(node_ids, id)

        _ ->
          invalid_property_graph!("invalid node", data)
      end
    end)
  end

  defp validate_property_graph_relationships!(relationships, node_ids, data) do
    Enum.each(relationships, fn relationship ->
      case relationship do
        %{from: source, to: destination, type: type, properties: properties}
        when is_binary(source) and is_binary(destination) and is_binary(type) and
               is_map(properties) ->
          unless String.trim(type) != "" do
            invalid_property_graph!("invalid relationship", data)
          end

          Enum.each([source, destination], fn endpoint ->
            unless MapSet.member?(node_ids, endpoint) do
              invalid_property_graph!("missing relationship endpoint #{inspect(endpoint)}", data)
            end
          end)

        _ ->
          invalid_property_graph!("invalid relationship", data)
      end
    end)
  end

  defp invalid_property_graph!(reason, data) do
    raise ArgumentError, "invalid property_graph data: #{reason}; got #{inspect(data)}"
  end

  @spec search(Search.t()) ::
          {:ok, [search_result() | reflection_search_result()]} | {:error, term()}
  def search(%Search{reflections: [_ | _]} = request) do
    validate_max_results!(request.max_results)
    reflections = registered_reflections!()

    selected = Enum.map(request.reflections, &reflection!(&1, reflections))

    Enum.reduce_while(selected, {:ok, []}, fn reflection, {:ok, results} ->
      opts = [max_results: request.max_results, artefact_id: request.artefact_id]

      case ReflectionStore.search(
             reflections,
             request.operator_id,
             reflection.name,
             request.query,
             opts
           ) do
        {:ok, artefacts} -> {:cont, {:ok, results ++ artefacts}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def search(%Search{
        operator_id: operator_id,
        query: query,
        lenses: lenses,
        max_results: max_results
      }) do
    validate_max_results!(max_results)

    targets =
      ["operator" | lenses]
      |> Enum.uniq()
      |> Enum.map(&search_target!(operator_id, &1))
      |> Enum.uniq_by(& &1.destination)

    targets
    |> Enum.map(fn target ->
      Task.async(fn -> {target.lens, Store.search(target.store, query, max_results)} end)
    end)
    |> Task.await_many(:infinity)
    |> Enum.reduce_while({:ok, []}, fn search_result, {:ok, results} ->
      case search_result do
        {lens_name, {:ok, lens_results}} ->
          attributed = Enum.map(lens_results, &%{lens: lens_name, fact: &1})
          {:cont, {:ok, results ++ attributed}}

        {_lens_name, {:error, _reason} = error} ->
          {:halt, error}
      end
    end)
  end

  @spec search_target!(String.t(), term()) :: search_target()
  defp search_target!(operator_id, "global") do
    %{
      destination: :global,
      lens: "global",
      store: %Store{operator_id: operator_id, lens: :global}
    }
  end

  defp search_target!(operator_id, name) when is_binary(name) do
    case lens!(name) do
      %{scope: :global} ->
        search_target!(operator_id, "global")

      %{name: lens_name, scope: :operator} = lens ->
        %{
          destination: {:operator, operator_id, lens_name},
          lens: lens_name,
          store: %Store{operator_id: operator_id, lens: lens}
        }
    end
  end

  defp search_target!(_operator_id, name),
    do: raise(ArgumentError, "invalid Lens #{inspect(name)}")

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
          ingestion: Keyword.fetch!(definition, :ingestion)
        }

      :replace_graph ->
        %ReplaceableLens{
          name: Keyword.fetch!(definition, :name),
          destination:
            fetch_lens_destination!(
              Keyword.fetch!(definition, :name),
              Keyword.get(definition, :destination)
            ),
          graph_format: Keyword.fetch!(definition, :graph_format)
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

    if name == "default" do
      raise ArgumentError,
            "invalid Lens \"default\": name was retired; use \"operator\" instead"
    end

    if name in ["operator", "global"] do
      raise ArgumentError, "invalid Lens #{inspect(name)}: name is reserved"
    end

    if Keyword.has_key?(definition, :scope) or Keyword.has_key?(definition, :ontology) do
      raise ArgumentError,
            "invalid Lens #{inspect(name)}: scoped address and ontology belong on a Destination"
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
        ingestion = Keyword.get(definition, :ingestion)

        fetch_lens_destination!(name, destination)

        unless is_atom(ingestion) and Code.ensure_loaded?(ingestion) and
                 function_exported?(ingestion, :ingest, 2) do
          raise ArgumentError, "invalid Lens #{inspect(name)} ingestion #{inspect(ingestion)}"
        end

      :replace_graph ->
        graph_format = Keyword.get(definition, :graph_format)

        fetch_lens_destination!(name, Keyword.get(definition, :destination))

        if Keyword.has_key?(definition, :ontology) or Keyword.has_key?(definition, :ingestion) do
          raise ArgumentError,
                "invalid Lens #{inspect(name)} combines appending and replaceable write settings"
        end

        unless graph_format == :property_graph do
          raise ArgumentError,
                "invalid Lens #{inspect(name)} graph format #{inspect(graph_format)}"
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

  defp registered_reflections! do
    ReflectionRegistry.configured!()
  end

  defp reflection!(name, reflections) when is_binary(name) do
    case Enum.find(reflections, &(&1.name == name)) do
      nil -> raise ArgumentError, "unknown Reflection #{inspect(name)}"
      reflection -> reflection
    end
  end

  defp reflection!(name, _reflections),
    do: raise(ArgumentError, "invalid Reflection #{inspect(name)}")

  @spec sanitize_group_id(String.t()) :: String.t()
  def sanitize_group_id(id) when is_binary(id), do: String.replace(id, "-", "_")
end
