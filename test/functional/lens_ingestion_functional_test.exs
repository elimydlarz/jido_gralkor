defmodule Gralkor.LensIngestionFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Ingest

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

  defmodule RecordingIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      send(Process.whereis(:lens_ingestion_functional), {:ingested, request, store})
      :ok
    end
  end

  defmodule VariableIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(%{content: "none"}, _store), do: :ok

    def ingest(%{content: "one", source_description: source}, store) do
      Gralkor.Lens.Store.add(store, "first", source)
    end

    def ingest(%{content: "many", source_description: source}, store) do
      with :ok <- Gralkor.Lens.Store.add(store, "first", source) do
        Gralkor.Lens.Store.add(store, "second", source)
      end
    end
  end

  defmodule FailingIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(_request, _store), do: {:error, :rejected}
  end

  defmodule RecordingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(store, content, source_description) do
      send(
        Process.whereis(:lens_ingestion_functional),
        {:episode_added, store, content, source_description}
      )

      :ok
    end

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    @impl true
    def replace_graph(_store, _graph) do
      send(Process.whereis(:lens_ingestion_functional), :graph_replaced)
      :ok
    end
  end

  setup do
    Process.register(self(), :lens_ingestion_functional)

    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)
    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations", address: "operator/observations", ontology: MemoryOntology]
    ])
    Application.put_env(:jido_gralkor, :lenses, [lens(RecordingIngestion)])

    on_exit(fn ->
      restore_env(:destinations, previous_destinations)
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when information is submitted through a registered Lens" do
    test "then the Lens's ingestion process receives the original information and a store bound to that Lens" do
      request = request("information")

      assert :ok = Client.ingest(request)

      assert_receive {:ingested, ^request,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens{name: "observations"}
                      }}
    end

    test "and the process may submit no episodes, one episode, or multiple episodes" do
      Application.put_env(:jido_gralkor, :lenses, [lens(VariableIngestion)])

      assert :ok = Client.ingest(request("none"))
      refute_receive {:episode_added, _, _, _}

      assert :ok = Client.ingest(request("one"))
      assert_receive {:episode_added, _, "first", "functional"}
      refute_receive {:episode_added, _, _, _}

      assert :ok = Client.ingest(request("many"))
      assert_receive {:episode_added, _, "first", "functional"}
      assert_receive {:episode_added, _, "second", "functional"}
      refute_receive {:episode_added, _, _, _}
    end

    test "and every submitted episode is governed by the selected Lens's Destination ontology and address" do
      Application.put_env(:jido_gralkor, :destinations, [
        [name: "observations", address: "global/observations", ontology: MemoryOntology]
      ])
      Application.put_env(:jido_gralkor, :lenses, [lens(VariableIngestion)])

      assert :ok = Client.ingest(request("one"))

      assert_receive {:episode_added,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens{
                          destination: %Gralkor.Destination{
                            name: "observations",
                            address: "global/observations",
                            ontology: MemoryOntology
                          }
                        }
                      }, "first", "functional"}
    end
  end

  describe "where information is submitted directly without a mounted plugin or conversational turn" do
    test "then the selected Lens's ingestion process runs without requiring an agent response or capture flush" do
      request = request("direct information")

      assert :ok = Client.ingest(request)
      assert_receive {:ingested, ^request, _store}
    end

    test "and the caller observes whether ingestion succeeded or failed" do
      assert :ok = Client.ingest(request("accepted"))

      Application.put_env(:jido_gralkor, :lenses, [lens(FailingIngestion)])
      assert {:error, :rejected} = Client.ingest(request("rejected"))
    end
  end

  describe "if ingestion selects an invalid Lens" do
    test "then ingestion fails before an ingestion process runs or memory is stored" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Client.ingest(%{request("information") | lens: "missing"})
      end

      refute_receive {:ingested, _, _}
      refute_receive {:episode_added, _, _, _}
    end
  end

  describe "if episode ingestion selects a replaceable Lens" do
    test "then ingestion fails with an error identifying that the Lens accepts only whole-graph replacement" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          destination: "observations",
          write: :replace_graph,
          graph_format: :property_graph
        ]
      ])

      assert_raise ArgumentError, ~r/observations.*only whole-graph replacement/, fn ->
        Client.ingest(request("information"))
      end
    end

    test "and no existing graph content is removed or inserted" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          destination: "observations",
          write: :replace_graph,
          graph_format: :property_graph
        ]
      ])

      assert_raise ArgumentError, fn -> Client.ingest(request("information")) end
      refute_receive :graph_replaced
      refute_receive {:episode_added, _, _, _}
    end
  end

  describe "if the selected Lens's ingestion process fails" do
    test "then ingestion returns that failure to the caller" do
      Application.put_env(:jido_gralkor, :lenses, [lens(FailingIngestion)])

      assert {:error, :rejected} = Client.ingest(request("rejected"))
    end

    test "and no fallback write bypasses the selected process" do
      Application.put_env(:jido_gralkor, :lenses, [lens(FailingIngestion)])

      assert {:error, :rejected} = Client.ingest(request("rejected"))
      refute_receive {:episode_added, _, _, _}
    end
  end

  defp lens(ingestion) do
    [
      name: "observations",
      destination: "observations",
      ingestion: ingestion
    ]
  end

  defp request(content) do
    %Ingest{
      operator_id: "operator-one",
      lens: "observations",
      content: content,
      source_description: "functional"
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
