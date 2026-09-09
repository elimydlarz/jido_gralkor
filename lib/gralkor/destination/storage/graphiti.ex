defmodule Gralkor.Destination.Storage.Graphiti do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  alias Gralkor.Destination
  alias Gralkor.Artefact
  alias Gralkor.GraphitiPool

  @impl true
  def put_artefact(output, reflection_name, operator_id, %Artefact{} = artefact) do
    put_artefact(output, reflection_name, operator_id, artefact, fn group_id,
                                                                    content,
                                                                    source_description,
                                                                    ontology,
                                                                    opts ->
      GraphitiPool.add_episode(
        GraphitiPool,
        group_id,
        content,
        source_description,
        ontology,
        opts
      )
    end)
  end

  @doc false
  def put_artefact(output, reflection_name, operator_id, %Artefact{} = artefact, add_episode) do
    case add_episode.(
           Destination.graph_id(output.destination, operator_id),
           Jason.encode!(Map.from_struct(artefact)),
           "reflection:#{reflection_name}",
           output.ontology,
           uuid: artefact.id
         ) do
      {:error, {:episode_conflict, id}} -> {:error, {:artefact_conflict, id}}
      outcome -> outcome
    end
  end

  @impl true
  def get_artefact(output, reflection_name, operator_id, artefact_id) do
    get_artefact(output, reflection_name, operator_id, artefact_id, &GraphitiPool.get_episode/2)
  end

  @doc false
  def get_artefact(output, _reflection_name, operator_id, artefact_id, get_episode) do
    case get_episode.(Destination.graph_id(output.destination, operator_id), artefact_id) do
      {:ok, episode} ->
        case decode_artefact(episode) do
          [%Artefact{id: ^artefact_id} = artefact] ->
            if extraction_complete?(episode) do
              {:ok, artefact}
            else
              {:error, {:incomplete_artefact, artefact}}
            end

          [%Artefact{}] ->
            {:error, {:artefact_conflict, artefact_id}}

          [] ->
            {:error, {:invalid_artefact, artefact_id}}
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def search(destination, operator_id, query, :facts, max_results, opts) do
    graph_id = Destination.graph_id(destination, operator_id)
    search_opts = Keyword.take(opts, [:edge_types, :lenses])

    case GraphitiPool.search(GraphitiPool, graph_id, query, max_results, search_opts) do
      {:ok, facts} ->
        {:ok,
         Enum.map(facts, fn fact ->
           case Map.fetch(fact, :sources) do
             {:ok, sources} -> Map.put(fact, :sources, Enum.map(sources, &fact_source/1))
             :error -> fact
           end
         end)}

      {:error, _} = error ->
        error
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
           require_reflection_complete: true,
           require_trusted_provenance: true
         ) do
      {:ok, episodes} -> structure_episodes(episodes)
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
          |> Enum.flat_map(&decode_artefact/1)
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

  defp fact_source(%{source_description: description} = source) when is_binary(description) do
    case Regex.run(~r/ \[lens: (.+)\]$/s, description) do
      [_, lens] ->
        Map.put(source, :lens, lens)

      _ ->
        case description do
          "reflection:" <> reflection when reflection != "" ->
            Map.put(source, :reflection, reflection)

          _ ->
            source
        end
    end
  end

  defp fact_source(source), do: source

  defp structure_episodes(episodes) do
    Enum.reduce_while(episodes, {:ok, []}, fn episode, {:ok, results} ->
      case episode_provenance(episode) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end

  defp episode_provenance(%{content: content, source_description: source_description} = episode) do
    case Regex.run(~r/^(.*) \[lens: (.+)\]$/s, source_description) do
      [_, source_description, lens] ->
        {:ok, Map.merge(episode, %{source_description: source_description, lens: lens})}

      _ ->
        reflection_episode(content, source_description)
    end
  end

  defp reflection_episode(content, "reflection:" <> reflection = source_description) do
    case decode_artefact(content) do
      [%Artefact{id: id, payload: payload}]
      when is_binary(id) and byte_size(id) > 0 and is_map(payload) ->
        {:ok,
         %{
           artefact: %{id: id, payload: payload},
           reflection: reflection,
           source_description: source_description
         }}

      _ ->
        {:error, {:invalid_reflection_artefact, reflection}}
    end
  end

  defp reflection_episode(content, source_description),
    do: {:ok, %{content: content, source_description: source_description}}

  @doc false
  def decode_artefact(%{content: content}), do: decode_artefact(content)
  def decode_artefact(%{"content" => content}), do: decode_artefact(content)

  def decode_artefact(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"id" => id, "payload" => payload} = decoded} when map_size(decoded) == 2 ->
        [%Artefact{id: id, payload: payload}]

      _ ->
        []
    end
  end

  def decode_artefact(_), do: []

  defp extraction_complete?(episode) do
    Map.get(episode, :extraction_complete, Map.get(episode, "extraction_complete", false)) == true
  end
end
