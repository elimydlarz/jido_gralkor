defmodule Gralkor.Destination.Storage do
  @moduledoc false

  alias Gralkor.Destination
  alias Gralkor.Artefact

  @callback search(
              Destination.t(),
              operator_id :: String.t(),
              query :: String.t(),
              Gralkor.Search.result_type(),
              max_results :: pos_integer(),
              keyword()
            ) :: {:ok, [term()]} | {:error, term()}

  @callback put_artefact(map(), String.t(), String.t(), Artefact.t()) ::
              :ok | {:error, term()}

  @callback get_artefact(map(), String.t(), String.t(), Artefact.t()) ::
              {:ok, Artefact.t()} | {:error, term()}

  @optional_callbacks put_artefact: 4, get_artefact: 4

  def search(destination, operator_id, query, result_type, max_results, opts) do
    storage().search(destination, operator_id, query, result_type, max_results, opts)
  end

  defp storage do
    Application.get_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.Graphiti
    )
  end
end
