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
    episodes = LensStorage.episodes(graph_id)

    {:ok,
     %{
       facts: episodes |> Enum.take(limits.facts) |> Enum.map(&fact/1),
       nodes: nodes(graph_id, Keyword.get(opts, :entity_types, []), limits.nodes),
       episodes: episodes(destination, operator_id, episodes, limits.episodes)
     }}
  end

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

  defp nodes(graph_id, selected_labels, limit) do
    graph_id
    |> LensStorage.graph()
    |> Map.fetch!(:nodes)
    |> Enum.filter(fn node ->
      selected_labels == [] or Enum.any?(node.labels, &(&1 in selected_labels))
    end)
    |> Enum.take(limit)
  end

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
