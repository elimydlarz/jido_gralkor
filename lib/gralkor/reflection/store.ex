defmodule Gralkor.Reflection.Store do
  @moduledoc "Stores and searches artefacts in destinations named by Reflections."

  alias Gralkor.Reflection
  alias Gralkor.Reflection.Artefact

  @callback put(Reflection.t(), String.t(), Artefact.t()) :: :ok | {:error, term()}
  @callback search(Reflection.t(), String.t(), String.t(), pos_integer()) ::
              {:ok, [Artefact.t()]} | {:error, term()}
  @callback get(Reflection.t(), String.t(), String.t()) ::
              {:ok, Artefact.t() | nil} | {:error, term()}

  def put(%Reflection{} = reflection, operator_id, %Artefact{} = artefact, opts \\ []) do
    storage(opts).put(reflection, operator_id, artefact)
  end

  def search(reflections, operator_id, name, query, opts \\ []) when is_list(reflections) do
    case Enum.find(reflections, &(&1.name == name)) do
      nil ->
        {:error, {:unknown_reflection, name}}

      reflection ->
        max_results = Keyword.get(opts, :max_results, 20)
        artefact_id = Keyword.get(opts, :artefact_id)

        if artefact_id do
          case storage(opts).get(reflection, operator_id, artefact_id) do
            {:ok, nil} -> {:ok, []}
            {:ok, artefact} -> {:ok, [artefact]}
            {:error, _} = error -> error
          end
        else
          storage(opts).search(reflection, operator_id, query, max_results)
        end
    end
  end

  def destination(%Reflection{name: name, scope: :global}, _operator_id),
    do: {:global, name}

  def destination(%Reflection{name: name, scope: :operator}, operator_id),
    do: {:operator, operator_id, name}

  defp storage(opts) do
    Keyword.get(
      opts,
      :storage,
      Application.get_env(:jido_gralkor, :reflection_storage, Gralkor.Reflection.Storage.Graphiti)
    )
  end
end
