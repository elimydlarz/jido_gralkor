defmodule Gralkor.Reflection.Store do
  @moduledoc """
  Canonical storage for artefacts in the Destinations named by Reflections.

  Implementations are part of the Scheduler's retry contract. `put/3` must be
  create-or-confirm by `artefact.id`: repeating the same immutable artefact
  returns `:ok` without creating another searchable artefact, while the same
  identifier with different immutable content returns
  `{:error, {:artefact_conflict, artefact_id}}`. `get/3` returns only durably
  completed artefacts; a stored but incomplete artefact may be returned as
  `{:error, {:incomplete_artefact, artefact}}` so storage can resume without
  rerunning the Runner.
  """

  alias Gralkor.Artefact
  alias Gralkor.Reflection

  @callback put(Reflection.t(), String.t(), Artefact.t()) ::
              :ok | {:error, {:artefact_conflict, String.t()} | term()}

  @callback get(Reflection.t(), String.t(), String.t()) ::
              {:ok, Artefact.t()}
              | {:error,
                 :not_found
                 | {:incomplete_artefact, Artefact.t()}
                 | {:artefact_conflict, String.t()}
                 | term()}

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
