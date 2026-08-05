defmodule Gralkor.Client do
  @moduledoc """
  Public entry point and adapter port for Gralkor memory.

  Named Lens operations use `ingest/1` and `search/1`. Ingestion resolves the
  application-owned Lens definition and invokes its ingestion process with a
  Lens-bound store. Search always begins with the requesting operator's
  reserved `"default"` Lens, then searches each additionally selected Lens.
  Every Lens resolves to the group its episodes live in, so naming a global
  Lens searches the whole shared `"global"` group; the originating Lens is
  attribution, not a search boundary.

  The compatibility surface remains `recall/4`, `capture/5`, `flush/1`,
  `flush_and_await/2`, and `memory_add/3` or `/4`. Lens-aware capture uses
  `capture/6`, or `capture/7` when the same turn is also routed through
  additional Lenses. Legacy group IDs are sanitised at their graph boundary
  (`sanitize_group_id/1`); Lens storage binds the original operator id to its
  selected Lens instead.

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
        lenses: lenses,
        max_results: max_results
      }) do
    lenses = Enum.uniq(["default" | lenses])
    Enum.each(lenses, &validate_search_lens!/1)

    Enum.reduce_while(lenses, {:ok, []}, fn lens_name, {:ok, results} ->
      case search_lens(operator_id, lens_name, query, max_results) do
        {:ok, lens_results} -> {:cont, {:ok, results ++ lens_results}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_search_lens!(term()) :: :ok
  defp validate_search_lens!("global"), do: :ok

  defp validate_search_lens!(name) when is_binary(name) do
    lens!(name)
    :ok
  end

  defp validate_search_lens!(name) do
    raise ArgumentError, "invalid Lens #{inspect(name)}"
  end

  @spec search_lens(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  defp search_lens(operator_id, "global", query, max_results) do
    Store.search(%Store{operator_id: operator_id, lens: :global}, query, max_results)
  end

  defp search_lens(operator_id, name, query, max_results) do
    Store.search(
      %Store{operator_id: operator_id, lens: lens!(name)},
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

    if name in ["default", "global"] do
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
