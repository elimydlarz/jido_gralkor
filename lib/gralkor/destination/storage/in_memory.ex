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
           nodes: [],
           episodes: episodes(destination, operator_id, episodes, limits.episodes)
         }}

      lenses ->
        lens_search(graph_id, lenses, limits)
    end
  end

  # Only what the selected Lenses wrote: their episodes and the facts this
  # backend derives from them. Direct writes and Destination artefacts never
  # match a Lens. This backend extracts no entities, so it returns no nodes.
  defp lens_search(graph_id, lenses, limits) do
    episodes = graph_id |> LensStorage.episodes() |> Enum.filter(&(Map.get(&1, :lens) in lenses))

    {:ok,
     %{
       facts: episodes |> Enum.take(limits.facts) |> Enum.map(&fact/1),
       nodes: [],
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
