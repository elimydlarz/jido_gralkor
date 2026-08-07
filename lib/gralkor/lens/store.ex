defmodule Gralkor.Lens.Store do
  @moduledoc """
  Storage capability passed to a `Gralkor.Lens.Ingestion` process.

  The Store is already bound to an operator and resolved Lens. Additions use
  that Lens's ontology and scope; searches and removals use its group.
  Ingestion processes should use this capability rather than choose Graphiti
  group IDs themselves.

  Global provenance is attached by the storage adapter and does not need to be
  supplied by the process.
  """

  alias Gralkor.Lens
  alias Gralkor.Lens.Replaceable

  @enforce_keys [:operator_id, :lens]
  defstruct [:operator_id, :lens]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          lens: Lens.t() | Replaceable.t() | :global
        }

  @spec add(t(), String.t(), String.t()) :: :ok | {:error, term()}
  @doc "Adds an episode through the bound Lens."
  def add(%__MODULE__{} = store, content, source_description) do
    storage().add_episode(store, content, source_description)
  end

  @spec replace_graph(t(), Gralkor.Graph.t()) :: :ok | {:error, term()}
  def replace_graph(%__MODULE__{} = store, graph) do
    storage().replace_graph(store, graph)
  end

  @spec search(t(), String.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  @doc "Searches the bound Lens's group."
  def search(%__MODULE__{} = store, query, max_results) do
    storage().search(store, query, max_results)
  end

  @spec storage() :: module()
  defp storage do
    Application.get_env(
      :jido_gralkor,
      :lens_storage,
      Gralkor.Lens.Storage.Graphiti
    )
  end
end
