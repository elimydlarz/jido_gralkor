defmodule Gralkor.Reflection.Store do
  @moduledoc "Stores artefacts in destinations named by Reflections."

  alias Gralkor.Reflection
  alias Gralkor.Reflection.Artefact

  @callback put(Reflection.t(), String.t(), Artefact.t()) :: :ok | {:error, term()}
  @callback get(Reflection.t(), String.t(), String.t()) ::
              {:ok, Artefact.t()} | {:error, :not_found | term()}

  def put(%Reflection{} = reflection, operator_id, %Artefact{} = artefact, opts \\ []) do
    storage(opts).put(reflection, operator_id, artefact)
  end

  def get(%Reflection{} = reflection, operator_id, artefact_id, opts \\ []) do
    storage(opts).get(reflection, operator_id, artefact_id)
  end

  def destination(%Reflection{destination: destination}, operator_id),
    do: Gralkor.Destination.graph_id(destination, operator_id)

  defp storage(opts) do
    Keyword.get(
      opts,
      :storage,
      Application.get_env(:jido_gralkor, :reflection_storage, Gralkor.Reflection.Storage.Graphiti)
    )
  end
end
