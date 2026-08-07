defmodule Gralkor.LensGraphReplacementFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Graph
  alias Gralkor.Replace

  defmodule RecordingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(_store, _content, _source_description), do: :ok

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    def replace_graph(store, graph) do
      send(Process.whereis(:lens_graph_replacement_functional), {:replaced, store, graph})
      :ok
    end
  end

  setup do
    Process.register(self(), :lens_graph_replacement_functional)

    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "systems",
        scope: :operator,
        write: :replace_graph,
        graph_format: :configured_format
      ]
    ])

    on_exit(fn ->
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when a caller replaces the complete graph through a replaceable Lens" do
    test "then the Lens scope resolves the same operator-local or shared global destination used by existing Lens operations" do
      graph = %Graph{format: :configured_format, data: %{nodes: [], relationships: []}}

      assert :ok =
               Client.replace(%Replace{
                 operator_id: "operator-one",
                 lens: "systems",
                 graph: graph
               })

      assert_receive {:replaced,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens{name: "systems", scope: :operator}
                      }, ^graph}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
