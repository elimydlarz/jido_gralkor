defmodule Gralkor.Lens.Storage.Graphiti do
  @moduledoc false

  @behaviour Gralkor.Lens.Storage

  alias Gralkor.GraphitiPool
  alias Gralkor.Lens
  alias Gralkor.Lens.Store

  @type add_episode_fn ::
          (String.t(), String.t(), String.t(), module() | nil, keyword() ->
             :ok | {:error, term()})

  @impl true
  def add_episode(%Store{} = store, content, source_description) do
    add_episode(store, content, source_description, [])
  end

  @spec add_episode(Store.t(), String.t(), String.t(),
          add_episode_fn: add_episode_fn()
        ) :: :ok | {:error, term()}
  def add_episode(
        %Store{operator_id: operator_id, lens: %Lens{scope: :operator} = lens},
        content,
        source_description,
        opts
      ) do
    add_episode_fn = Keyword.get(opts, :add_episode_fn, &graph_add/5)

    add_episode_fn.(
      local_destination(operator_id, lens.name),
      content,
      source_description,
      lens.ontology,
      []
    )
  end

  @spec local_destination(String.t(), String.t()) :: String.t()
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
end
