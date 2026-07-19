defmodule Gralkor.Lens.Store do
  @moduledoc """
  Storage capability passed to a `Gralkor.Lens.Ingestion` process.

  The Store is already bound to an operator and resolved Lens. Additions use
  that Lens's ontology and scope; searches use its destination; removals use
  the same destination. Ingestion processes should use this capability rather
  than choose Graphiti partitions themselves.

  `add/4` accepts episode options such as `:uuid` when a process needs stable
  identity for later replacement or removal. Global provenance is attached by
  the storage adapter and does not need to be supplied by the process.
  """

  alias Gralkor.Lens

  @enforce_keys [:operator_id, :lens]
  defstruct [:operator_id, :lens]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          lens: Lens.t() | :global
        }

  @spec add(t(), String.t(), String.t()) :: :ok | {:error, term()}
  @doc "Adds an episode through the bound Lens."
  def add(%__MODULE__{} = store, content, source_description) do
    storage().add_episode(store, content, source_description)
  end

  @spec add(t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @doc "Adds an episode through the bound Lens with storage options."
  def add(%__MODULE__{} = store, content, source_description, opts) do
    storage().add_episode(store, content, source_description, opts)
  end

  @spec remove(t(), String.t()) :: :ok | {:error, term()}
  @doc "Removes an episode by identity from the bound Lens destination."
  def remove(%__MODULE__{} = store, episode_id) do
    storage().remove_episode(store, episode_id)
  end

  @spec search(t(), String.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  @doc "Searches the bound Lens destination."
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
