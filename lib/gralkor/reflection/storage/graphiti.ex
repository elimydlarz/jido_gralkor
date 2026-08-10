defmodule Gralkor.Reflection.Storage.Graphiti do
  @moduledoc false
  @behaviour Gralkor.Reflection.Store

  alias Gralkor.GraphitiPool
  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.Store

  @impl true
  def put(reflection, operator_id, %Artefact{} = artefact) do
    GraphitiPool.add_episode(
      group_id(reflection, operator_id),
      Jason.encode!(Map.from_struct(artefact)),
      "reflection:#{reflection.name}",
      nil
    )
  end

  @impl true
  def search(reflection, operator_id, query, max_results) do
    case GraphitiPool.search_episodes(
           GraphitiPool,
           group_id(reflection, operator_id),
           query,
           max_results
         ) do
      {:ok, episodes} -> {:ok, Enum.flat_map(episodes, &decode/1)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def get(reflection, operator_id, artefact_id) do
    case search(reflection, operator_id, artefact_id, 20) do
      {:ok, artefacts} -> {:ok, Enum.find(artefacts, &(&1.id == artefact_id))}
      {:error, _} = error -> error
    end
  end

  defp group_id(reflection, operator_id) do
    Store.destination(reflection, operator_id)
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
    |> then(&("reflection_" <> &1))
  end

  defp decode(%{content: content}), do: decode(content)
  defp decode(%{"content" => content}), do: decode(content)

  defp decode(content) when is_binary(content) do
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

  defp decode(_), do: []
end
