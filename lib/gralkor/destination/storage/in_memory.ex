defmodule Gralkor.Destination.Storage.InMemory do
  @moduledoc false
  @behaviour Gralkor.Destination.Storage

  use Agent

  alias Gralkor.Destination
  alias Gralkor.Lens.Storage.InMemory, as: LensStorage

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{} end, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def put_artefact(output, reflection_name, operator_id, artefact) do
    graph_id = Destination.graph_id(output.destination, operator_id)

    Agent.get_and_update(__MODULE__, fn state ->
      entries = Map.get(state, graph_id, [])

      case Enum.find(entries, &(&1.artefact.id == artefact.id)) do
        nil ->
          entry = %{artefact: artefact, reflection: reflection_name}
          {:ok, Map.put(state, graph_id, entries ++ [entry])}

        %{artefact: ^artefact} ->
          {:ok, state}

        _entry ->
          {{:error, {:artefact_conflict, artefact.id}}, state}
      end
    end)
  end

  @impl true
  def get_artefact(output, _reflection_name, operator_id, artefact_id) do
    graph_id = Destination.graph_id(output.destination, operator_id)

    Agent.get(__MODULE__, fn state ->
      case Enum.find(Map.get(state, graph_id, []), &(&1.artefact.id == artefact_id)) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry.artefact}
      end
    end)
  end

  @impl true
  def search(destination, operator_id, _query, opts) do
    limits = Keyword.fetch!(opts, :limits)
    graph_id = Destination.graph_id(destination, operator_id)

    case Keyword.get(opts, :lenses, []) do
      [] ->
        episodes = LensStorage.episodes(graph_id)

        {:ok,
         %{
           facts: episodes |> Enum.take(limits.facts) |> Enum.map(&fact/1),
           nodes: nodes(graph_id, Keyword.get(opts, :entity_types, []), limits.nodes),
           episodes: episodes(destination, operator_id, episodes, limits.episodes)
         }}

      lenses ->
        lens_search(graph_id, lenses, Keyword.get(opts, :entity_types, []), limits)
    end
  end

  # Only what the selected Lenses wrote: their episodes (and the facts this
  # backend derives from them), the relationships and nodes their graph
  # replacements own. Direct writes and Destination artefacts never match a Lens.
  defp lens_search(graph_id, lenses, selected_labels, limits) do
    episodes = graph_id |> LensStorage.episodes() |> Enum.filter(&(Map.get(&1, :lens) in lenses))

    replacement_facts =
      graph_id
      |> LensStorage.graph()
      |> Map.fetch!(:relationships)
      |> Enum.filter(&(Map.get(&1.properties, :_gralkor_lens) in lenses))
      |> Enum.map(&replacement_fact/1)

    nodes =
      graph_id
      |> nodes(selected_labels, :infinity)
      |> Enum.filter(&(Map.get(&1.properties, :_gralkor_lens) in lenses))
      |> Enum.take(limits.nodes)

    {:ok,
     %{
       facts:
         episodes |> Enum.map(&fact/1) |> Kernel.++(replacement_facts) |> Enum.take(limits.facts),
       nodes: nodes,
       episodes: episodes |> Enum.take(limits.episodes) |> Enum.map(&episode_result/1)
     }}
  end

  defp episode_result(episode),
    do:
      Map.take(episode, [:content, :source_kind, :lens, :reflection, :writer, :source_description])

  defp fact(episode) do
    %{
      fact: episode.content,
      relationship: nil,
      source_node: nil,
      target_node: nil,
      sources: [
        Map.take(episode, [:id, :source_kind, :lens, :reflection, :writer, :source_description])
      ]
    }
  end

  defp replacement_fact(relationship) do
    %{
      fact: Map.get(relationship.properties, :fact),
      relationship: Map.get(relationship.properties, :name, relationship.type),
      source_node: %{uuid: relationship.from, name: nil},
      target_node: %{uuid: relationship.to, name: nil}
    }
  end

  defp nodes(graph_id, selected_labels, limit) do
    graph_id
    |> LensStorage.graph()
    |> Map.fetch!(:nodes)
    |> Enum.filter(fn node ->
      selected_labels == [] or Enum.any?(node.labels, &(&1 in selected_labels))
    end)
    |> take(limit)
  end

  defp take(nodes, :infinity), do: nodes
  defp take(nodes, limit), do: Enum.take(nodes, limit)

  defp episodes(destination, operator_id, lens_episodes, limit) do
    reflection_episodes =
      if Process.whereis(__MODULE__) do
        destination
        |> artefact_entries(operator_id)
        |> Enum.map(fn %{artefact: artefact, reflection: reflection} ->
          %{
            artefact: Map.from_struct(artefact),
            source_description: "reflection:#{reflection}",
            reflection: reflection
          }
        end)
      else
        []
      end

    lens_episodes =
      Enum.map(
        lens_episodes,
        &Map.take(&1, [:content, :source_kind, :lens, :reflection, :writer, :source_description])
      )

    Enum.take(reflection_episodes ++ lens_episodes, limit)
  end

  defp artefact_entries(destination, operator_id) do
    graph_id = Destination.graph_id(destination, operator_id)
    Agent.get(__MODULE__, &Map.get(&1, graph_id, []))
  end
end
