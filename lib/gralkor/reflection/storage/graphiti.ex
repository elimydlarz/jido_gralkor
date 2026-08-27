defmodule Gralkor.Reflection.Storage.Graphiti do
  @moduledoc false
  @behaviour Gralkor.Reflection.Store

  alias Gralkor.GraphitiPool
  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.Store

  @impl true
  def put(reflection, operator_id, %Artefact{} = artefact) do
    put(reflection, operator_id, artefact, &GraphitiPool.add_episode/4)
  end

  @doc false
  def put(reflection, operator_id, %Artefact{} = artefact, add_episode) do
    add_episode.(
      group_id(reflection, operator_id),
      Jason.encode!(Map.from_struct(artefact)),
      "reflection:#{reflection.name}",
      reflection.ontology
    )
  end

  defp group_id(reflection, operator_id) do
    Store.destination(reflection, operator_id)
  end

  @doc false
  def decode(%{content: content}), do: decode(content)
  def decode(%{"content" => content}), do: decode(content)

  def decode(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok,
       %{
         "id" => id,
         "reflection" => reflection,
         "payload" => payload,
         "evidence_ids" => evidence_ids
       }} ->
        [%Artefact{id: id, reflection: reflection, payload: payload, evidence_ids: evidence_ids}]

      _ ->
        []
    end
  end

  def decode(_), do: []
end
