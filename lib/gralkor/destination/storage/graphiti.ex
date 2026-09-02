defmodule Gralkor.Destination.Storage.Graphiti do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  alias Gralkor.Destination
  alias Gralkor.Format
  alias Gralkor.GraphitiPool

  @impl true
  def put_artefact(output, reflection_name, operator_id, artefact) do
    Gralkor.Reflection.Storage.Graphiti.put_output(
      output,
      reflection_name,
      operator_id,
      artefact
    )
  end

  @impl true
  def get_artefact(output, reflection_name, operator_id, artefact_id) do
    Gralkor.Reflection.Storage.Graphiti.get_output(
      output,
      reflection_name,
      operator_id,
      artefact_id
    )
  end

  @impl true
  def search(destination, operator_id, query, :facts, max_results, opts) do
    graph_id = Destination.graph_id(destination, operator_id)
    search_opts = Keyword.take(opts, [:edge_types])

    case GraphitiPool.search(GraphitiPool, graph_id, query, max_results, search_opts) do
      {:ok, facts} -> {:ok, Enum.map(facts, &Format.format_fact/1)}
      {:error, _} = error -> error
    end
  end

  def search(destination, operator_id, query, :nodes, max_results, opts) do
    GraphitiPool.search_nodes(
      GraphitiPool,
      Destination.graph_id(destination, operator_id),
      query,
      max_results,
      node_labels: Keyword.get(opts, :entity_types)
    )
  end

  def search(destination, operator_id, query, :episodes, max_results, opts) do
    case GraphitiPool.search_episodes(
           GraphitiPool,
           Destination.graph_id(destination, operator_id),
           query,
           max_results,
           lenses: Keyword.get(opts, :lenses, []),
           require_reflection_complete: true
         ) do
      {:ok, episodes} -> {:ok, Enum.map(episodes, &episode_provenance/1)}
      {:error, _} = error -> error
    end
  end

  def search(destination, operator_id, query, :artefacts, max_results, opts) do
    search_query = Keyword.get(opts, :artefact_id) || query

    case GraphitiPool.search_episodes(
           GraphitiPool,
           Destination.graph_id(destination, operator_id),
           search_query,
           max_results,
           require_extraction_complete: true,
           converge_by_identity: true
         ) do
      {:ok, episodes} ->
        artefacts =
          episodes
          |> Enum.flat_map(&Gralkor.Reflection.Storage.Graphiti.decode/1)
          |> filter_artefact(Keyword.get(opts, :artefact_id))

        converge_artefacts(artefacts, max_results)

      {:error, _} = error ->
        error
    end
  end

  defp filter_artefact(artefacts, nil), do: artefacts
  defp filter_artefact(artefacts, id), do: Enum.filter(artefacts, &(&1.id == id))

  defp converge_artefacts(artefacts, max_results) do
    conflict =
      artefacts
      |> Enum.group_by(& &1.id)
      |> Enum.find_value(fn {id, matching} ->
        if matching |> MapSet.new() |> MapSet.size() > 1, do: id
      end)

    if conflict do
      {:error, {:artefact_conflict, conflict}}
    else
      {:ok, artefacts |> Enum.uniq_by(& &1.id) |> Enum.take(max_results)}
    end
  end

  defp episode_provenance(%{content: content, source_description: source_description}) do
    case Regex.run(~r/^(.*) \[lens: (.+)\]$/s, source_description) do
      [_, source_description, lens] ->
        %{content: content, source_description: source_description, lens: lens}

      _ ->
        reflection_episode(content, source_description)
    end
  end

  defp reflection_episode(content, "reflection:" <> reflection),
    do: %{content: content, reflection: reflection}

  defp reflection_episode(content, source_description),
    do: %{content: content, source_description: source_description}
end
