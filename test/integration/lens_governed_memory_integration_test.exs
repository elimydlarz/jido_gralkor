defmodule Gralkor.LensGovernedMemoryIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Gralkor.Client
  alias Gralkor.Ingest
  alias Gralkor.Search
  alias JidoGralkor.Plugin

  defmodule ObservationOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Observation do
      field(:content, :string, required: true)
    end
  end

  defmodule RecordingIngestion do
    def ingest(request, store) do
      send(Process.whereis(:lens_governed_memory_integration), {:ingested, request, store})
      :ok
    end
  end

  defmodule StoreAddingIngestion do
    alias Gralkor.Lens.Store

    def ingest(request, store) do
      Store.add(store, request.content, request.source_description)
    end
  end

  defmodule VariableWriteIngestion do
    alias Gralkor.Lens.Store

    def ingest(%{content: "none"}, _store), do: :ok

    def ingest(%{content: "one", source_description: source_description}, store) do
      Store.add(store, "one", source_description)
    end

    def ingest(%{content: "many", source_description: source_description}, store) do
      with :ok <- Store.add(store, "first", source_description) do
        Store.add(store, "second", source_description)
      end
    end
  end

  defmodule FailingIngestion do
    def ingest(_request, _store), do: {:error, :rejected}
  end

  defmodule RecordingStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(store, content, source_description) do
      send(
        Process.whereis(:lens_governed_memory_integration),
        {:add_episode, store, content, source_description}
      )

      :ok
    end

    @impl true
    def search(_store, _query, _max_results), do: {:ok, []}
  end

  setup do
    Process.register(self(), :lens_governed_memory_integration)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        ontology: ObservationOntology,
        scope: :operator,
        ingestion: RecordingIngestion
      ]
    ])

    on_exit(fn ->
      case previous_lenses do
        nil -> Application.delete_env(:jido_gralkor, :lenses)
        lenses -> Application.put_env(:jido_gralkor, :lenses, lenses)
      end

      case previous_storage do
        nil -> Application.delete_env(:jido_gralkor, :lens_storage)
        storage -> Application.put_env(:jido_gralkor, :lens_storage, storage)
      end
    end)

    :ok
  end

  describe "when an application registers a Lens with a non-blank name, ontology, local or global scope, and ingestion process" do
    test "then direct callers and mounted memory plugins can select that Lens by name" do
      request = %Ingest{
        operator_id: "operator-one",
        lens: "observations",
        content: "The launch window moved to Friday.",
        source_description: "project update"
      }

      assert :ok = Client.ingest(request)
      assert_receive {:ingested, ^request, %{lens: %{name: "observations"}}}

      opts = %{
        agent_name: "Susu",
        default_lens: "observations",
        search_targets: ["observations"]
      }

      assert {:ok, mount} = Plugin.mount(%{}, opts)
      assert mount.default_lens == "observations"
    end

    test "and every plugin mount observes the same application-owned Lens definition" do
      first_opts = %{
        agent_name: "Susu",
        default_lens: "observations",
        search_targets: ["observations"],
        ontology: nil,
        scope: :global,
        ingestion: String
      }

      second_opts = %{
        agent_name: "Momo",
        default_lens: "observations",
        search_targets: ["observations"]
      }

      assert {:ok, first_mount} = Plugin.mount(%{}, first_opts)
      assert {:ok, second_mount} = Plugin.mount(%{}, second_opts)
      assert first_mount.lens == second_mount.lens
      assert first_mount.lens.ontology == ObservationOntology
      assert first_mount.lens.scope == :operator
      assert first_mount.lens.ingestion == RecordingIngestion
    end
  end

  describe "when information is submitted through a registered Lens" do
    test "then the Lens's ingestion process receives the information and a store bound to that Lens" do
      request = %Ingest{
        operator_id: "operator-one",
        lens: "observations",
        content: "The launch window moved to Friday.",
        source_description: "project update"
      }

      assert :ok = Client.ingest(request)

      assert_receive {:ingested, ^request,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens{
                          name: "observations",
                          ontology: ObservationOntology,
                          scope: :operator,
                          ingestion: RecordingIngestion
                        }
                      }}
    end

    test "and every episode the process asks the store to add uses the Lens's ontology and storage scope" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: StoreAddingIngestion
        ]
      ])

      request = %Ingest{
        operator_id: "operator-one",
        lens: "observations",
        content: "The launch window moved to Friday.",
        source_description: "project update"
      }

      assert :ok = Client.ingest(request)

      assert_receive {:add_episode,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens{
                          name: "observations",
                          ontology: ObservationOntology,
                          scope: :operator,
                          ingestion: StoreAddingIngestion
                        }
                      }, "The launch window moved to Friday.", "project update"}
    end

    test "and the process may add no episodes, one episode, or multiple episodes without changing those bindings" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: VariableWriteIngestion
        ]
      ])

      request = fn content ->
        %Ingest{
          operator_id: "operator-one",
          lens: "observations",
          content: content,
          source_description: "project update"
        }
      end

      assert :ok = Client.ingest(request.("none"))
      refute_receive {:add_episode, _, _, _}

      assert :ok = Client.ingest(request.("one"))

      assert_receive {:add_episode,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %{name: "observations", ontology: ObservationOntology, scope: :operator}
                      }, "one", "project update"}

      assert :ok = Client.ingest(request.("many"))
      assert_receive {:add_episode, %{lens: %{name: "observations"}}, "first", "project update"}
      assert_receive {:add_episode, %{lens: %{name: "observations"}}, "second", "project update"}
    end
  end

  describe "where information is submitted directly without a mounted plugin or conversational turn" do
    test "then the selected Lens's ingestion process runs without requiring an agent response or capture flush" do
      request = %Ingest{
        operator_id: "operator-one",
        lens: "observations",
        content: "The launch window moved to Friday.",
        source_description: "project update"
      }

      assert :ok = Client.ingest(request)
      assert_receive {:ingested, ^request, %{lens: %{name: "observations"}}}
    end

    test "and the caller observes whether ingestion succeeded or failed" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "rejected",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: FailingIngestion
        ]
      ])

      request = %Ingest{
        operator_id: "operator-one",
        lens: "rejected",
        content: "Do not retain this.",
        source_description: "consumer policy"
      }

      assert {:error, :rejected} = Client.ingest(request)
    end
  end

  describe "when an operator-local Lens adds an episode" do
    test "then the episode is available only through that Lens for that operator" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: StoreAddingIngestion
        ]
      ])

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 content: "The launch window moved to Friday.",
                 source_description: "project update"
               })

      assert {:ok, ["The launch window moved to Friday."]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "launch window",
                 targets: ["observations"]
               })
    end

    test "and a Lens with the same name belonging to another operator cannot observe it" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: StoreAddingIngestion
        ]
      ])

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 content: "The launch window moved to Friday.",
                 source_description: "project update"
               })

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "launch window",
                 targets: ["observations"]
               })
    end

    test "and another operator-local Lens belonging to the same operator cannot observe it" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: StoreAddingIngestion
        ],
        [
          name: "decisions",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: StoreAddingIngestion
        ]
      ])

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 content: "The launch window moved to Friday.",
                 source_description: "project update"
               })

      assert {:ok, []} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "launch window",
                 targets: ["decisions"]
               })
    end
  end
end
