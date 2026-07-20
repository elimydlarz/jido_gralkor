defmodule Gralkor.Lens.Storage.Graphiti do
  @moduledoc false

  @behaviour Gralkor.Lens.Storage

  alias Gralkor.GraphitiPool
  alias Gralkor.Lens
  alias Gralkor.Lens.Store

  @type add_episode_fn ::
          (String.t(), String.t(), String.t(), module() | nil, keyword() ->
             :ok | {:error, term()})
  @type search_fn ::
          (String.t(), String.t(), pos_integer() ->
             {:ok, [String.t()]} | {:error, term()})

  @impl true
  def add_episode(%Store{} = store, content, source_description) do
    add_episode(store, content, source_description, [])
  end

  @spec add_episode(Store.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def add_episode(
        %Store{operator_id: operator_id, lens: %Lens{scope: :operator} = lens},
        content,
        source_description,
        opts
      ) do
    {add_episode_fn, episode_opts} = add_options(opts)

    add_episode_fn.(
      local_destination(operator_id, lens.name),
      content,
      source_description,
      lens.ontology,
      episode_opts
    )
  end

  def add_episode(
        %Store{lens: %Lens{scope: :global} = lens},
        content,
        source_description,
        opts
      ) do
    {add_episode_fn, episode_opts} = add_options(opts)

    add_episode_fn.(
      "global",
      content,
      source_description,
      lens.ontology,
      Keyword.delete(episode_opts, :lens) ++ [lens: lens.name]
    )
  end

  @impl Gralkor.Lens.Storage
  def search(%Store{} = store, query, max_results) do
    search(store, query, max_results, [])
  end

  @spec search(Store.t(), String.t(), pos_integer(), search_fn: search_fn()) ::
          {:ok, [String.t()]} | {:error, term()}
  def search(
        %Store{operator_id: operator_id, lens: %Lens{scope: :operator} = lens},
        query,
        max_results,
        opts
      ) do
    search_fn = Keyword.get(opts, :search_fn, &graph_search/3)
    search_fn.(local_destination(operator_id, lens.name), query, max_results)
  end

  def search(%Store{lens: %Lens{scope: :global}}, query, max_results, opts) do
    search_fn = Keyword.get(opts, :search_fn, &graph_search/3)
    search_fn.("global", query, max_results)
  end

  def search(%Store{lens: :global}, query, max_results, opts) do
    search_fn = Keyword.get(opts, :search_fn, &graph_search/3)
    search_fn.("global", query, max_results)
  end

  @spec local_destination(String.t(), String.t()) :: String.t()
  defp local_destination(operator_id, "default"), do: String.replace(operator_id, "-", "_")

  defp local_destination(operator_id, lens_name) do
    "lens_" <> encode(operator_id) <> "_" <> encode(lens_name)
  end

  @spec encode(String.t()) :: String.t()
  defp encode(value), do: Base.encode16(value, case: :lower)

  @spec graph_add(String.t(), String.t(), String.t(), module() | nil, keyword()) ::
          :ok | {:error, term()}
  defp graph_add(destination, content, source_description, ontology, graph_opts) do
    GraphitiPool.add_episode(destination, content, source_description, ontology, graph_opts)
  end

  @spec add_options(keyword()) :: {add_episode_fn(), keyword()}
  defp add_options(opts) do
    case Keyword.pop(opts, :add_episode_fn, &graph_add/5) do
      {add_episode_fn, []} ->
        {add_episode_fn, []}

      {_add_episode_fn, unsupported} ->
        raise ArgumentError, "unsupported add options #{inspect(unsupported)}"
    end
  end

  @spec graph_search(String.t(), String.t(), pos_integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  defp graph_search(destination, query, max_results) do
    case GraphitiPool.search(destination, query, max_results) do
      {:ok, facts} -> {:ok, Enum.map(facts, &Gralkor.Format.format_fact/1)}
      {:error, _reason} = error -> error
    end
  end
end
