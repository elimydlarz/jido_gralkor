defmodule Gralkor.Client do
  @moduledoc """
  Port for talking to a Gralkor backend from Elixir.

  Operations — recall, capture, flush, flush_and_await, memory_add,
  build_indices, build_communities. Every failure is reported as
  `{:error, reason}` so callers can decide how to fail open. Group IDs are
  sanitised at the edge (`sanitize_group_id/1`) to satisfy FalkorDB's
  RediSearch constraint.

  `flush/1` returns `:ok` before the buffered turns have landed
  (fire-and-forget — appropriate for shutdown paths that cannot block).
  `flush_and_await/2` returns `:ok` only after the episode is queryable via
  `recall/4`, for callers that must observe completion before rotating
  state (e.g. session-id rotation in `JidoGralkor.ContextRotator`).

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
  @type ontology :: module() | nil

  alias Gralkor.Ingest
  alias Gralkor.Lens
  alias Gralkor.Lens.Ingestion.Store, as: StoreIngestion
  alias Gralkor.Lens.Store
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
              content :: String.t(),
              source_description :: String.t() | nil,
              ontology()
            ) ::
              :ok | {:error, term()}
  @callback flush(session_id()) :: :ok | {:error, term()}
  @callback flush_and_await(session_id(), timeout_ms :: pos_integer()) ::
              :ok | {:error, :timeout} | {:error, term()}
  @callback build_indices() :: {:ok, %{status: String.t()}} | {:error, term()}
  @callback build_communities(group_id()) ::
              {:ok, %{communities: non_neg_integer(), edges: non_neg_integer()}}
              | {:error, term()}
  @callback generalise(group_id(), transcript :: String.t()) :: :ok | {:error, term()}
  @callback search_generalisations(group_id(), query :: String.t(), max_results :: pos_integer()) ::
              {:ok, [Gralkor.Generalisation.t()]} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:jido_gralkor, :client, Gralkor.Client.Native)

  @spec ingest(Ingest.t()) :: :ok | {:error, term()}
  def ingest(%Ingest{lens: lens_name} = request) do
    lens = lens!(lens_name)
    store = %Store{operator_id: request.operator_id, lens: lens}
    lens.ingestion.ingest(request, store)
  end

  @spec search(Search.t()) :: {:ok, [String.t()]} | {:error, term()}
  def search(%Search{
        operator_id: operator_id,
        query: query,
        targets: [_target | _rest] = targets,
        max_results: max_results
      }) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, results} ->
      case search_target(operator_id, target, query, max_results) do
        {:ok, target_results} -> {:cont, {:ok, results ++ target_results}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec search_target(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  defp search_target(operator_id, "global", query, max_results) do
    Store.search(%Store{operator_id: operator_id, lens: :global}, query, max_results)
  end

  defp search_target(operator_id, target, query, max_results) do
    lens = lens!(target)

    if lens.scope == :global do
      raise ArgumentError,
            "global Lens #{inspect(target)} is provenance; search the reserved \"global\" target"
    end

    Store.search(
      %Store{operator_id: operator_id, lens: lens},
      query,
      max_results
    )
  end

  @spec lens!(String.t()) :: Lens.t()
  def lens!(name) do
    lenses = registered_lenses!()

    case Enum.find(lenses, fn definition -> Keyword.get(definition, :name) == name end) do
      nil when name == "default" ->
        %Lens{
          name: "default",
          ontology: Gralkor.Config.ontology(),
          scope: :operator,
          ingestion: StoreIngestion
        }

      nil ->
        raise ArgumentError, "unknown Lens #{inspect(name)}"

      definition ->
        %Lens{
          name: Keyword.fetch!(definition, :name),
          ontology: Keyword.fetch!(definition, :ontology),
          scope: Keyword.fetch!(definition, :scope),
          ingestion: Keyword.fetch!(definition, :ingestion)
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
    name = Keyword.get(definition, :name)
    ontology = Keyword.get(definition, :ontology)
    scope = Keyword.get(definition, :scope)
    ingestion = Keyword.get(definition, :ingestion)

    unless is_binary(name) and String.trim(name) != "" do
      raise ArgumentError, "invalid Lens name #{inspect(name)}"
    end

    if name == "global" do
      raise ArgumentError, "invalid Lens #{inspect(name)}: name is reserved"
    end

    unless is_atom(ontology) and Code.ensure_loaded?(ontology) and
             function_exported?(ontology, :__ontology__, 0) do
      raise ArgumentError, "invalid Lens #{inspect(name)} ontology #{inspect(ontology)}"
    end

    unless scope in [:operator, :global] do
      raise ArgumentError, "invalid Lens #{inspect(name)} scope #{inspect(scope)}"
    end

    unless is_atom(ingestion) and Code.ensure_loaded?(ingestion) and
             function_exported?(ingestion, :ingest, 2) do
      raise ArgumentError, "invalid Lens #{inspect(name)} ingestion #{inspect(ingestion)}"
    end
  end

  defp validate_lens!(definition) do
    raise ArgumentError, "invalid Lens definition #{inspect(definition)}"
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

  @spec sanitize_group_id(String.t()) :: String.t()
  def sanitize_group_id(id) when is_binary(id), do: String.replace(id, "-", "_")
end
