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
  def search(destination, operator_id, query, opts) do
    search(destination, operator_id, query, opts, fn group_id, query, limits, pool_opts ->
      GraphitiPool.search_memory(GraphitiPool, group_id, query, limits, pool_opts)
    end)
  end

  @doc false
  def search(destination, operator_id, query, opts, search_memory) do
    case search_memory.(
           Destination.graph_id(destination, operator_id),
           query,
           Keyword.fetch!(opts, :limits),
           node_labels: Keyword.get(opts, :entity_types),
           edge_types: Keyword.get(opts, :edge_types),
           lenses: Keyword.get(opts, :lenses)
         ) do
      {:ok, %{facts: facts, nodes: nodes, episodes: episodes}} ->
        with {:ok, episodes} <- structure_episodes(episodes) do
          {:ok, %{facts: Enum.map(facts, &fact_provenance/1), nodes: nodes, episodes: episodes}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp fact_provenance(fact) do
    case Map.fetch(fact, :sources) do
      {:ok, sources} -> Map.put(fact, :sources, Enum.map(sources, &fact_source/1))
      :error -> fact
    end
  end

  defp fact_source(%{writer: :direct} = source), do: source

  defp fact_source(%{source_description: description} = source) when is_binary(description) do
    if String.ends_with?(description, " [gralkor: direct]") do
      source
    else
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
    if Map.get(episode, :writer) == :direct do
      {:ok,
       episode
       |> Map.put(
         :source_description,
         String.replace_suffix(source_description, " [gralkor: direct]", "")
       )
       |> Map.put(:writer, :direct)}
    else
      if String.ends_with?(source_description, " [gralkor: direct]") do
        {:ok, episode}
      else
        named_episode_provenance(episode, content, source_description)
      end
    end
  end

  defp named_episode_provenance(episode, content, source_description) do
    case Regex.run(~r/^(.*) \[lens: (.+)\]$/s, source_description) do
      [_, source_description, lens] ->
        {:ok, Map.merge(episode, %{source_description: source_description, lens: lens})}

      _ ->
        if String.starts_with?(source_description, "reflection:") do
          reflection_episode(content, source_description)
        else
          {:ok, episode}
        end
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

  @doc false
  def decode_artefact(%{content: content}), do: decode_artefact(content)
  def decode_artefact(%{"content" => content}), do: decode_artefact(content)

  def decode_artefact(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"id" => id, "payload" => payload} = decoded}
      when map_size(decoded) == 2 and is_binary(id) and is_map(payload) ->
        if String.trim(id) == "", do: [], else: [%Artefact{id: id, payload: payload}]

      _ ->
        []
    end
  end

  def decode_artefact(_), do: []

  defp extraction_complete?(episode) do
    Map.get(episode, :extraction_complete, Map.get(episode, "extraction_complete", false)) == true
  end
end
