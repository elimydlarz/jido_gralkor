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

  defmodule PartiallyFailingIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(%{source_description: source}, store) do
      :ok = Gralkor.Lens.Store.add(store, "stored before failure", source)
      {:error, :rejected}
    end
  end

  defmodule SearchingIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(%{content: query}, store) do
      send(
        Process.whereis(:lens_ingestion_functional),
        {:searched, Gralkor.Lens.Store.search(store, query, 2)}
      )

      :ok
    end
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

  defmodule RecordingGraphitiStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(store, content, source_description) do
      test_pid = Process.whereis(:lens_ingestion_functional)

      Gralkor.Lens.Storage.Graphiti.add_episode(store, content, source_description,
        add_episode_fn: fn group_id, episode, source, ontology, opts ->
          send(test_pid, {:graph_add, group_id, episode, source, ontology, opts})
          :ok
        end
      )
    end

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}

    @impl true
    def replace_graph(_store, _graph), do: :ok
  end

  setup do
    Process.register(self(), :lens_ingestion_functional)

    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations"]
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

    test "and every submitted episode is saved to the selected Lens's Destination" do
      Application.put_env(:jido_gralkor, :lenses, [lens(VariableIngestion)])

      assert :ok = Client.ingest(request("one"))

      assert_receive {:episode_added,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens{
                          destination: %Gralkor.Destination{name: "observations"}
                        }
                      }, "first", "functional"}
    end

    test "and every submitted episode is extracted through the selected Lens's ontology" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingGraphitiStorage)
      Application.put_env(:jido_gralkor, :lenses, [lens(VariableIngestion)])

      assert :ok = Client.ingest(request("one"))

      assert_receive {:graph_add, "observations", "first", "functional", MemoryOntology, _}
    end

    test "and every directly submitted episode retains the selected Lens identity as source provenance" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingGraphitiStorage)
      Application.put_env(:jido_gralkor, :lenses, [lens(VariableIngestion)])

      assert :ok = Client.ingest(request("one"))

      assert_receive {:graph_add, _, "first", "functional", MemoryOntology,
                      [source_kind: :document, lens: "observations"]}
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

    test "and completed ingestion neither resolves nor invokes configured Reflections" do
      test_pid = self()

      start_supervised!(
        {JidoGralkor.Runtime,
         owner: test_pid,
         configuration: runtime_configuration(),
         run_reflection: fn reflection, invocation, _opts ->
           send(test_pid, {:reflection_ran, reflection.name, invocation.id})
           {:ok, Gralkor.Artefact.new("review-artefact", %{"summary" => "reviewed"})}
         end,
         deliver_artefact: fn _output, _reflection, _operator, _artefact -> :ok end}
      )

      assert :ok = Client.ingest(test_pid, request("one"))
      assert_receive {:episode_added, _, "first", "functional"}
      refute_receive {:reflection_ran, _, _}

      assert {:ok, "review-invocation"} =
               Client.reflect(
                 test_pid,
                 "review",
                 %{
                   id: "review-invocation",
                   operator_id: "operator-one",
                   invocation_context: %{},
                   representations: []
                 },
                 fn _outcome -> :ok end
               )

      assert_receive {:reflection_ran, "review", "review-invocation"}
    end
  end

  describe "where completed representations are requested" do
    test "then each successful Store write yields one `Gralkor.IngestedRepresentation`" do
      Application.put_env(:jido_gralkor, :lenses, [lens(VariableIngestion)])

      assert {:ok,
              [
                %Gralkor.IngestedRepresentation{lens: "observations", result: :ok},
                %Gralkor.IngestedRepresentation{lens: "observations", result: :ok}
              ]} = Client.ingest_with_representation(request("many"))
    end

    test "and the representations are returned in Store write order" do
      Application.put_env(:jido_gralkor, :lenses, [lens(VariableIngestion)])

      assert {:ok, [%{content: "first"}, %{content: "second"}]} =
               Client.ingest_with_representation(request("many"))
    end
  end

  describe "when a Lens ingestion process searches through its bound Store" do
    test "then only the selected Lens's Destination graph for the request's operator is searched" do
      use_searchable_graph()

      assert :ok = Client.ingest(request("launch window"))

      assert_receive {:searched, {:ok, _facts}}
      assert_received {:graph_instance, group_id}
      assert group_id == Client.sanitize_group_id("personal/operator-one")
      refute_received {:graph_instance, _other_group}
    end

    test "and no more than the requested number of results is returned" do
      graphiti = use_searchable_graph()

      assert :ok = Client.ingest(request("launch window"))

      assert_receive {:searched, {:ok, facts}}
      assert length(facts) == 2
      {limits, _} = Pythonx.eval("g.requested_limits", %{"g" => graphiti})
      assert Pythonx.decode(limits) == [2]
    end
  end

  describe "if ingestion has a missing or blank ingestion identifier or operator identifier" do
    test "then ingestion raises an argument error naming the rejected identifier" do
      for {field, value} <- rejected_identifiers() do
        assert_raise ArgumentError,
                     ~r/\A#{field} must be a non-blank string, got #{Regex.escape(inspect(value))}/,
                     fn -> Client.ingest(Map.put(request("information"), field, value)) end
      end
    end

    test "and no Lens ingestion process runs" do
      for {field, value} <- rejected_identifiers() do
        assert_raise ArgumentError, fn ->
          Client.ingest(Map.put(request("information"), field, value))
        end
      end

      refute_receive {:ingested, _, _}
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
          write: :replace_graph
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
          write: :replace_graph
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

  describe "if the selected Lens's ingestion process fails > while one or more Store writes completed before the failure" do
    test "then no partial list of `Gralkor.IngestedRepresentation` values is returned" do
      Application.put_env(:jido_gralkor, :lenses, [lens(PartiallyFailingIngestion)])

      assert {:error, :rejected} = Client.ingest_with_representation(request("partial"))
      assert_receive {:episode_added, _, "stored before failure", "functional"}
    end
  end

  defp rejected_identifiers do
    [{:id, nil}, {:id, "  "}, {:operator_id, nil}, {:operator_id, ""}]
  end

  defp use_searchable_graph do
    test_pid = self()
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.Graphiti)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        destination: "personal",
        ontology: MemoryOntology,
        ingestion: SearchingIngestion
      ]
    ])

    {graphiti, _} =
      Pythonx.eval(
        """
        class _Edge:
            def __init__(self, fact):
                self.fact = fact
                self.episodes = []
                self.created_at = None
                self.valid_at = None
                self.invalid_at = None
                self.expired_at = None

        class _Graphiti:
            def __init__(self):
                self.requested_limits = []
                self.facts = [_Edge(f"launch fact {index}") for index in range(5)]
                self.driver = None
                self.llm_client = None

            async def search(self, query, num_results=10, search_filter=None):
                self.requested_limits.append(num_results)
                return self.facts[:num_results]

        _Graphiti()
        """,
        %{}
      )

    start_supervised!(
      {Gralkor.GraphitiPool,
       name: Gralkor.GraphitiPool,
       table: :gralkor_graphiti_instances,
       falkordb_spec: {:embedded, "/tmp/never_used"},
       construct_falkor_db: fn _spec -> :stub_falkor_db end,
       construct_shared_clients: fn _llm, _embedder ->
         %{llm_client: nil, embedder: nil, cross_encoder: nil}
       end,
       construct_instance: fn _db, _shared, group_id ->
         send(test_pid, {:graph_instance, group_id})
         graphiti
       end,
       initialise_instance: fn _instance -> :ok end,
       warmup: false,
       install_loop_fn: &Gralkor.Python.install_async_runtime/0}
    )

    graphiti
  end

  defp lens(ingestion) do
    [
      name: "observations",
      destination: "observations",
      ontology: MemoryOntology,
      ingestion: ingestion
    ]
  end

  defp runtime_configuration do
    %{
      destinations: [%{name: "observations"}],
      lenses: [
        %{
          name: "observations",
          destination: "observations",
          write: :append,
          ontology: MemoryOntology,
          ingestion: VariableIngestion
        }
      ],
      reflections: [
        %{
          name: "review",
          outputs: [%{kind: :destination, destination: "observations"}],
          chain_of_thought: %{
            steps: [
              %{label: "review", directions: "Review.", output: %{"summary" => "string"}}
            ]
          }
        }
      ]
    }
  end

  defp request(content) do
    %Ingest{
      id: "lens-ingestion-#{System.unique_integer([:positive])}",
      operator_id: "operator-one",
      lens: "observations",
      source_kind: :document,
      content: content,
      source_description: "functional"
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
