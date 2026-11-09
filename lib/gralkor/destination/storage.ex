defmodule Gralkor.Destination.Storage do
  @moduledoc false

  alias Gralkor.Destination
  alias Gralkor.Artefact

  @typedoc "What one Destination contributes to a search, each kind in relevance order."
  @type search_result :: %{facts: [map()], nodes: [map()], episodes: [map()]}

  @doc """
  Searches one Destination for facts, nodes, and episodes together.

  Options: `:limits` (`%{facts:, nodes:, episodes:}`, required), `:entity_types`,
  `:edge_types`, `:writers`, and `:excluded_writers` (optional lists of writer
  names, see `Gralkor.Search`). Included `:writers` restrict every kind to
  what those writers produced before ranking and limits; `:excluded_writers`
  leave out, before ranking and limits, the excluded writers' episodes and the
  facts and entities only they produced.
  """
  @callback search(
              Destination.t(),
              operator_id :: String.t(),
              query :: String.t(),
              keyword()
            ) :: {:ok, search_result()} | {:error, term()}

  @callback put_artefact(map(), String.t(), String.t(), Artefact.t()) ::
              :ok | {:error, term()}

  @callback get_artefact(map(), String.t(), String.t(), String.t()) ::
              {:ok, Artefact.t()} | {:error, term()}

  @optional_callbacks put_artefact: 4, get_artefact: 4

  def search(destination, operator_id, query, opts) do
    configured_storage().search(destination, operator_id, query, opts)
  end

  def put_artefact(output, reflection_name, operator_id, artefact, opts \\ []) do
    storage(opts).put_artefact(output, reflection_name, operator_id, artefact)
  end

  def get_artefact(output, reflection_name, operator_id, artefact_id, opts \\ []) do
    storage(opts).get_artefact(output, reflection_name, operator_id, artefact_id)
  end

  defp storage(opts), do: Keyword.get(opts, :storage, configured_storage())

  defp configured_storage do
    Application.get_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.Graphiti
    )
  end
end
