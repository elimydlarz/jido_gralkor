defmodule Gralkor.Lens.Store do
  @moduledoc """
  Storage capability passed to a `Gralkor.Lens.Ingestion` process.

  The Store is already bound to an operator and resolved Lens. Additions use
  an appending Lens's ontology and scope; complete replacements use a
  replaceable Lens's graph format and ownership; searches use its destination.
  Ingestion processes should use this capability rather than choose Graphiti
  group IDs themselves.

  Global provenance is attached by the storage adapter and does not need to be
  supplied by the process.
  """

  alias Gralkor.Lens
  alias Gralkor.Lens.Replaceable
  alias Gralkor.IngestedRepresentation

  @enforce_keys [:operator_id, :lens]
  defstruct [:operator_id, :lens, :source_kind, :evidence_id, :representation_collector]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          lens: Lens.t() | Replaceable.t() | :global,
          source_kind: Gralkor.Ingest.source_kind() | nil,
          evidence_id: String.t() | nil,
          representation_collector: (IngestedRepresentation.t() -> any()) | nil
        }

  @spec add(t(), String.t(), String.t()) :: :ok | {:error, term()}
  @doc "Adds an episode through the bound Lens."
  def add(%__MODULE__{} = store, content, source_description) do
    case storage().add_episode(store, content, source_description) do
      :ok ->
        collect_representation(store, content)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @spec replace_graph(t(), Gralkor.Graph.t()) :: :ok | {:error, term()}
  @doc "Replaces the complete graph owned by the bound replaceable Lens."
  def replace_graph(%__MODULE__{} = store, graph) do
    storage().replace_graph(store, graph)
  end

  @spec search(t(), String.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  @doc "Searches the bound Lens's group."
  def search(%__MODULE__{} = store, query, max_results) do
    storage().search(store, query, max_results)
  end

  defp collect_representation(
         %__MODULE__{
           lens: %Lens{name: lens},
           evidence_id: evidence_id,
           representation_collector: collector
         },
         content
       )
       when is_binary(evidence_id) and is_function(collector, 1) do
    collector.(IngestedRepresentation.new(evidence_id, lens, content))
  end

  defp collect_representation(_store, _content), do: :ok

  @spec storage() :: module()
  defp storage do
    Application.get_env(
      :jido_gralkor,
      :lens_storage,
      Gralkor.Lens.Storage.Graphiti
    )
  end
end
