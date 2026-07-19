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

  defmodule GeneralisationOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Generalisation do
      field(:content, :string, required: true)
    end
  end

  defmodule RecordingIngestion do
    def ingest(request, store) do
      send(Process.whereis(:lens_governed_memory_integration), {:ingested, request, store})
      :ok
    end
  end

  defmodule GeneralisationRecordingIngestion do
    def ingest(request, store) do
      send(Process.whereis(:lens_governed_memory_integration), {:generalised, request, store})
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
    def add_episode(store, content, source_description, opts) do
      send(
        Process.whereis(:lens_governed_memory_integration),
        {:add_episode, store, content, source_description, opts}
      )

      :ok
    end

    @impl true
    def remove_episode(_store, _episode_id), do: :ok

    @impl true
    def search(store, query, max_results) do
      send(
        Process.whereis(:lens_governed_memory_integration),
        {:search, store, query, max_results}
      )

      {:ok, []}
    end
  end

  setup do
    Process.register(self(), :lens_governed_memory_integration)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)
    previous_client = Application.get_env(:jido_gralkor, :client)
    previous_ontology = Application.get_env(:jido_gralkor, :ontology)
    previous_hypothesise = Application.get_env(:jido_gralkor, :generalise_hypothesise_fn)
    previous_evaluate = Application.get_env(:jido_gralkor, :generalise_evaluate_fn)

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

      case previous_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        client -> Application.put_env(:jido_gralkor, :client, client)
      end

      case previous_ontology do
        nil -> Application.delete_env(:jido_gralkor, :ontology)
        ontology -> Application.put_env(:jido_gralkor, :ontology, ontology)
      end

      case previous_hypothesise do
        nil -> Application.delete_env(:jido_gralkor, :generalise_hypothesise_fn)
        fun -> Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fun)
      end

      case previous_evaluate do
        nil -> Application.delete_env(:jido_gralkor, :generalise_evaluate_fn)
        fun -> Application.put_env(:jido_gralkor, :generalise_evaluate_fn, fun)
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
                        lens: %{
                          name: "observations",
                          ontology: ObservationOntology,
                          scope: :operator
                        }
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

  describe "when a global Lens adds an episode" do
    test "then the episode enters the one global pool shared by every global Lens and every operator" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "published-observations",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ],
        [
          name: "published-decisions",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ]
      ])

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "published-observations",
                 content: "The public launch window moved to Friday.",
                 source_description: "public project update"
               })

      assert {:ok, ["The public launch window moved to Friday."]} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "launch window",
                 targets: ["global"]
               })
    end

    test "and the episode records the name of the Lens that ingested it" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "published-observations",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ]
      ])

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "published-observations",
                 content: "The public launch window moved to Friday.",
                 source_description: "public project update"
               })

      assert [
               %{
                 content: "The public launch window moved to Friday.",
                 lens: "published-observations"
               }
             ] =
               Gralkor.Lens.Storage.InMemory.episodes(:global)
    end

    test "and the ingestion process does not have to add Lens provenance itself" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "published-observations",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ]
      ])

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "published-observations",
                 content: "The public launch window moved to Friday.",
                 source_description: "public project update"
               })

      assert [%{lens: "published-observations"}] =
               Gralkor.Lens.Storage.InMemory.episodes(:global)
    end
  end

  describe "when a caller searches a non-empty selection of operator-local Lenses and the reserved `global` target" do
    test "then each selected operator-local Lens is searched only for the requesting operator" do
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
        ],
        [
          name: "published-observations",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ]
      ])

      for {operator_id, lens, content} <- [
            {"operator-one", "observations", "operator-one observation"},
            {"operator-one", "decisions", "operator-one decision"},
            {"operator-one", "published-observations", "public observation"},
            {"operator-two", "observations", "operator-two observation"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: operator_id,
                   lens: lens,
                   content: content,
                   source_description: "test source"
                 })
      end

      assert {:ok, results} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "observation or decision",
                 targets: ["observations", "decisions", "global"]
               })

      assert results == [
               "operator-one observation",
               "operator-one decision",
               "public observation"
             ]
    end

    test "and selecting the global pool searches every episode in that pool without filtering by originating Lens" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "published-observations",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ],
        [
          name: "published-decisions",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ]
      ])

      for {lens, content} <- [
            {"published-observations", "public observation"},
            {"published-decisions", "public decision"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "test source"
                 })
      end

      assert {:ok, ["public observation", "public decision"]} =
               Client.search(%Search{
                 operator_id: "operator-two",
                 query: "public",
                 targets: ["global"]
               })
    end

    test "and results from all selected destinations are combined into one memory response" do
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

      for {lens, content} <- [
            {"observations", "operator observation"},
            {"decisions", "operator decision"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "test source"
                 })
      end

      assert {:ok, ["operator observation", "operator decision"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["observations", "decisions"]
               })
    end

    test "and no unselected operator-local Lens or another operator's local memory can contribute a result" do
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

      for {operator_id, lens, content} <- [
            {"operator-one", "observations", "selected observation"},
            {"operator-one", "decisions", "unselected decision"},
            {"operator-two", "observations", "other operator observation"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: operator_id,
                   lens: lens,
                   content: content,
                   source_description: "test source"
                 })
      end

      assert {:ok, ["selected observation"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "memory",
                 targets: ["observations"]
               })
    end
  end

  describe "where a global Lens name identifies an episode's origin" do
    test "then that name remains attribution rather than a search boundary" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "published-observations",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ],
        [
          name: "published-decisions",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ]
      ])

      for {lens, content} <- [
            {"published-observations", "public observation"},
            {"published-decisions", "public decision"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "test source"
                 })
      end

      assert Enum.map(Gralkor.Lens.Storage.InMemory.episodes(:global), & &1.lens) == [
               "published-observations",
               "published-decisions"
             ]

      assert {:ok, ["public observation", "public decision"]} =
               Client.search(%Search{
                 operator_id: "operator-one",
                 query: "public",
                 targets: ["global"]
               })
    end

    test "and `global` is the only target that selects globally stored memory" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "published-observations",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ]
      ])

      assert_raise ArgumentError, ~r/global/, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "public",
          targets: ["published-observations"]
        })
      end
    end
  end

  describe "when a mounted plugin has a configured default Lens and search targets" do
    test "then automatic capture and memory addition use the registered default Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations"]
               )

      signal = %Jido.Signal{
        id: "signal-one",
        source: "/test",
        type: "ai.react.query",
        data: %{query: "remember this"}
      }

      agent = %{
        id: "operator-one",
        state: %{__memory__: plugin_state, __thread__: %{id: "session-one"}}
      }

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, %{agent: agent})

      assert {:ok, %{result: "Ingesting."}} =
               JidoGralkor.Actions.MemoryAdd.run(
                 %{content: "The launch window moved.", source_description: "agent thought"},
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert_receive {:ingested,
                      %Ingest{
                        operator_id: "operator-one",
                        lens: "observations",
                        content: "The launch window moved.",
                        source_description: "agent thought"
                      }, %{lens: %{name: "observations"}}}
    end

    test "and memory search uses the configured search targets" do
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
        ],
        [
          name: "published",
          ontology: ObservationOntology,
          scope: :global,
          ingestion: StoreAddingIngestion
        ]
      ])

      for {lens, content} <- [
            {"observations", "selected observation"},
            {"decisions", "unselected decision"},
            {"published", "selected public memory"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   operator_id: "operator-one",
                   lens: lens,
                   content: content,
                   source_description: "test"
                 })
      end

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations", "global"]
               )

      signal = %Jido.Signal{
        id: "signal-two",
        source: "/test",
        type: "ai.react.query",
        data: %{query: "memory"}
      }

      agent = %{
        id: "operator-one",
        state: %{__memory__: plugin_state, __thread__: %{id: "session-one"}}
      }

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, %{agent: agent})

      assert {:ok, %{result: result}} =
               JidoGralkor.Actions.MemorySearch.run(
                 %{query: "memory"},
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert result =~ "selected observation"
      assert result =~ "selected public memory"
      refute result =~ "unselected decision"
    end

    test "and the plugin does not redefine the selected Lenses' ontology, scope, or ingestion process" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations"]
               )

      assert %Gralkor.Lens{
               name: "observations",
               ontology: ObservationOntology,
               scope: :operator,
               ingestion: RecordingIngestion
             } = plugin_state.lens
    end
  end

  describe "where a turn supplies a registered Lens through plugin context" do
    test "then that Lens overrides the plugin's default Lens for ingestion during that turn" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: FailingIngestion
        ],
        [
          name: "decisions",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: RecordingIngestion
        ]
      ])

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations"]
               )

      signal = %Jido.Signal{
        id: "signal-three",
        source: "/test",
        type: "ai.react.query",
        data: %{query: "remember this", tool_context: %{lens: "decisions"}}
      }

      agent = %{
        id: "operator-one",
        state: %{__memory__: plugin_state, __thread__: %{id: "session-one"}}
      }

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, %{agent: agent})

      assert {:ok, %{result: "Ingesting."}} =
               JidoGralkor.Actions.MemoryAdd.run(
                 %{content: "We chose Friday.", source_description: "agent decision"},
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert_receive {:ingested, %Ingest{lens: "decisions"},
                      %{
                        lens: %{
                          name: "decisions",
                          ontology: ObservationOntology,
                          scope: :operator,
                          ingestion: RecordingIngestion
                        }
                      }}
    end

    test "and the application-owned definition of the selected Lens remains authoritative" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: RecordingIngestion
        ]
      ])

      assert %Gralkor.Lens{
               name: "observations",
               ontology: ObservationOntology,
               scope: :operator,
               ingestion: RecordingIngestion
             } = Client.lens!("observations")
    end
  end

  describe "if a mounted plugin selects an unknown default Lens, invalid search target, unknown or duplicate generalising Lens, or Lens options without a default Lens" do
    test "then mounting fails before the plugin handles an agent signal" do
      assert_raise ArgumentError, ~r/unknown Lens/, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          default_lens: "missing",
          search_targets: ["observations"]
        )
      end

      assert_raise ArgumentError, ~r/unknown Lens/, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          default_lens: "observations",
          search_targets: ["missing"]
        )
      end

      for invalid_targets <- [[], nil, [123]] do
        assert_raise ArgumentError, fn ->
          Plugin.mount(%{},
            agent_name: "Susu",
            default_lens: "observations",
            search_targets: invalid_targets
          )
        end
      end

      assert_raise ArgumentError, ~r/unknown Lens/, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          default_lens: "observations",
          search_targets: ["observations"],
          generalise_lens: "missing"
        )
      end

      assert_raise ArgumentError, ~r/differ/, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          default_lens: "observations",
          search_targets: ["observations"],
          generalise_lens: "observations"
        )
      end

      for orphan_opts <- [
            [search_targets: ["observations"]],
            [generalise_lens: "observations"]
          ] do
        assert_raise ArgumentError, ~r/default_lens/, fn ->
          Plugin.mount(%{}, Keyword.merge([agent_name: "Susu"], orphan_opts))
        end
      end
    end
  end

  describe "when turns in one session select different Lenses" do
    test "then each Lens receives only the turns selected for it" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: RecordingIngestion
        ],
        [
          name: "decisions",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: RecordingIngestion
        ]
      ])

      lens_flush = fn operator_id, agent_name, user_name, lens, turns ->
        transcript = Gralkor.Distill.format_transcript(turns, agent_name, user_name)

        Client.ingest(%Ingest{
          operator_id: operator_id,
          lens: lens,
          content: transcript,
          source_description: "captured"
        })
      end

      start_supervised!(
        {Gralkor.CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end, lens_flush_callback: lens_flush, retries: []}
      )

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations", "decisions"]
               )

      requests = %{
        "request-one" => %{query: "The launch moved.", status: :pending, result: nil},
        "request-two" => %{query: "We chose Friday.", status: :pending, result: nil}
      }

      traces = %{
        "request-one" => %{events: [%{kind: :llm_completed, data: %{}}]},
        "request-two" => %{events: [%{kind: :llm_completed, data: %{}}]}
      }

      agent = %{
        id: "operator-one",
        state: %{
          __memory__: plugin_state,
          __thread__: %{id: "session-one"},
          __strategy__: %{request_traces: traces},
          requests: requests,
          user_name: "Eli"
        }
      }

      for {request_id, result, lens} <- [
            {"request-one", "I noted that.", "observations"},
            {"request-two", "Decision recorded.", "decisions"}
          ] do
        signal = %Jido.Signal{
          id: "signal-#{request_id}",
          source: "/test",
          type: "ai.request.completed",
          data: %{
            request_id: request_id,
            result: result,
            tool_context: %{lens: lens}
          }
        }

        assert {:ok, :continue} = Plugin.handle_signal(signal, %{agent: agent})
      end

      assert [observation_turn, decision_turn] =
               Gralkor.CaptureBuffer.turns_for("session-one")

      assert [%Gralkor.Message{content: "The launch moved."} | _] = observation_turn
      assert [%Gralkor.Message{content: "We chose Friday."} | _] = decision_turn

      assert :ok = Gralkor.Client.Native.flush_and_await("session-one", 1_000)

      assert_receive {:ingested, %Ingest{lens: "observations", content: observation_transcript},
                      %{lens: %{name: "observations"}}}

      assert observation_transcript =~ "The launch moved."
      refute observation_transcript =~ "We chose Friday."

      assert_receive {:ingested, %Ingest{lens: "decisions", content: decision_transcript},
                      %{lens: %{name: "decisions"}}}

      assert decision_transcript =~ "We chose Friday."
      refute decision_transcript =~ "The launch moved."
    end

    test "and no flushed episode combines turns governed by different ontologies or ingestion processes" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: RecordingIngestion
        ],
        [
          name: "generalisations",
          ontology: GeneralisationOntology,
          scope: :operator,
          ingestion: GeneralisationRecordingIngestion
        ]
      ])

      start_supervised!(
        {Gralkor.CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
         retries: []}
      )

      assert :ok =
               Gralkor.Client.Native.capture(
                 "session-isolated",
                 "operator-one",
                 "Susu",
                 "Eli",
                 [%Gralkor.Message{role: "user", content: "Observed rain."}],
                 "observations"
               )

      assert :ok =
               Gralkor.Client.Native.capture(
                 "session-isolated",
                 "operator-one",
                 "Susu",
                 "Eli",
                 [%Gralkor.Message{role: "user", content: "Rain delays launches."}],
                 "generalisations"
               )

      assert :ok = Gralkor.Client.Native.flush_and_await("session-isolated", 1_000)

      assert_receive {:ingested, %Ingest{content: observation_transcript}, observation_store}

      assert_receive {:generalised, %Ingest{content: generalisation_transcript},
                      generalisation_store}

      assert observation_transcript =~ "Observed rain."
      refute observation_transcript =~ "Rain delays launches."
      assert observation_store.lens.ontology == ObservationOntology

      assert generalisation_transcript =~ "Rain delays launches."
      refute generalisation_transcript =~ "Observed rain."
      assert generalisation_store.lens.ontology == GeneralisationOntology
    end

    test "and before flush the session's complete turn order remains available as recall context" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      start_supervised!(
        {Gralkor.CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: fn _, _, _, _, _ -> :ok end,
         retries: []}
      )

      assert :ok =
               Gralkor.Client.Native.capture(
                 "session-order",
                 "operator-one",
                 "Susu",
                 "Eli",
                 [%Gralkor.Message{role: "user", content: "first"}],
                 "observations"
               )

      assert :ok =
               Gralkor.Client.Native.capture(
                 "session-order",
                 "operator-one",
                 "Susu",
                 "Eli",
                 [%Gralkor.Message{role: "user", content: "second"}],
                 "decisions"
               )

      assert [
               [%Gralkor.Message{content: "first"}],
               [%Gralkor.Message{content: "second"}]
             ] = Gralkor.CaptureBuffer.turns_for("session-order")
    end
  end

  describe "where an application has not registered or selected a named Lens" do
    test "then the implicit `default` Lens preserves the operator's existing memory partition" do
      Application.delete_env(:jido_gralkor, :lenses)
      Application.put_env(:jido_gralkor, :ontology, ObservationOntology)
      Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "default",
                 content: "A compatible memory.",
                 source_description: "legacy caller"
               })

      assert_receive {:add_episode,
                      %Gralkor.Lens.Store{
                        operator_id: "operator-one",
                        lens: %Gralkor.Lens{
                          name: "default",
                          ontology: ObservationOntology,
                          scope: :operator
                        }
                      }, "A compatible memory.", "legacy caller"}
    end

    test "and an unset `:jido_gralkor, :ontology` preserves generic extraction" do
      Application.delete_env(:jido_gralkor, :lenses)
      Application.delete_env(:jido_gralkor, :ontology)

      assert %Gralkor.Lens{
               name: "default",
               ontology: nil,
               scope: :operator,
               ingestion: Gralkor.Lens.Ingestion.Store
             } = Client.lens!("default")
    end

    test "and the `:jido_gralkor, :ontology` value remains its ontology" do
      Application.delete_env(:jido_gralkor, :lenses)
      Application.put_env(:jido_gralkor, :ontology, ObservationOntology)

      assert %Gralkor.Lens{name: "default", ontology: ObservationOntology} =
               Client.lens!("default")
    end

    test "and existing capture, memory addition, and recall preserve legacy behavior under that compatibility mapping" do
      Application.delete_env(:jido_gralkor, :lenses)

      assert %Gralkor.Lens{name: "default", scope: :operator} = Client.lens!("default")
      Code.ensure_loaded!(Gralkor.Client.Native)
      assert function_exported?(Gralkor.Client.Native, :capture, 5)
      assert function_exported?(Gralkor.Client.Native, :memory_add, 3)
      assert function_exported?(Gralkor.Client.Native, :recall, 4)
    end
  end

  describe "if Lens registration is invalid (blank, duplicate, reserved `default` or `global`, or malformed)" do
    test "then configuration resolution raises `ArgumentError` naming the invalid Lens before ingestion or search begins" do
      invalid_registries = [
        [
          [
            name: " ",
            ontology: ObservationOntology,
            scope: :operator,
            ingestion: RecordingIngestion
          ]
        ],
        [
          [
            name: "observations",
            ontology: ObservationOntology,
            scope: :operator,
            ingestion: RecordingIngestion
          ],
          [
            name: "observations",
            ontology: ObservationOntology,
            scope: :operator,
            ingestion: RecordingIngestion
          ]
        ],
        [
          [
            name: "global",
            ontology: ObservationOntology,
            scope: :global,
            ingestion: RecordingIngestion
          ]
        ],
        [
          [
            name: "default",
            ontology: ObservationOntology,
            scope: :operator,
            ingestion: RecordingIngestion
          ]
        ],
        [[name: "broken", ontology: String, scope: :operator, ingestion: RecordingIngestion]],
        [
          [
            name: "broken",
            ontology: ObservationOntology,
            scope: :tenant,
            ingestion: RecordingIngestion
          ]
        ],
        [[name: "broken", ontology: ObservationOntology, scope: :operator, ingestion: String]]
      ]

      Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

      for registry <- invalid_registries do
        Application.put_env(:jido_gralkor, :lenses, registry)

        assert_raise ArgumentError, ~r/Lens/, fn ->
          Client.ingest(%Ingest{
            operator_id: "operator-one",
            lens: "observations",
            content: "must not write",
            source_description: "invalid registry"
          })
        end

        refute_receive {:add_episode, _, _, _}
      end
    end
  end

  describe "if ingestion names an unknown or blank Lens" do
    test "then ingestion fails before an ingestion process or graph write is started" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

      for lens <- ["missing", " "] do
        assert_raise ArgumentError, ~r/Lens/, fn ->
          Client.ingest(%Ingest{
            operator_id: "operator-one",
            lens: lens,
            content: "must not write",
            source_description: "invalid request"
          })
        end

        refute_receive {:ingested, _, _}
        refute_receive {:add_episode, _, _, _}
      end
    end
  end

  describe "if search supplies an empty selection or a target that is neither a registered operator-local Lens nor `global`" do
    test "then search fails before any memory query is started" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

      for targets <- [[], ["observations", "missing"]] do
        assert_raise ArgumentError, fn ->
          Client.search(%Search{
            operator_id: "operator-one",
            query: "anything",
            targets: targets
          })
        end

        refute_receive {:search, _, _, _}
      end
    end

    test "and no valid subset is searched" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

      assert_raise ArgumentError, fn ->
        Client.search(%Search{
          operator_id: "operator-one",
          query: "anything",
          targets: ["observations", "missing"]
        })
      end

      refute_receive {:search, _, _, _}
    end
  end

  describe "when a transcript is submitted through Gralkor's generalising ingestion process" do
    test "then hypotheses are evaluated against generalisations available through the selected Lens" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "generalisations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: Gralkor.Lens.Ingestion.Generalise
        ]
      ])

      lens = Client.lens!("generalisations")
      store = %Gralkor.Lens.Store{operator_id: "operator-one", lens: lens}

      existing = %Gralkor.Generalisation{
        id: "existing-one",
        content: "Eli sometimes chooses Friday.",
        level: 0,
        confidence: 0.6,
        generalises: []
      }

      assert :ok =
               Gralkor.Lens.Store.add(
                 store,
                 Gralkor.Generalisation.encode(existing),
                 "generalisation"
               )

      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok, [%{content: "Eli prefers Friday launches.", confidence: 0.9}]}
      end)

      test_pid = self()

      Application.put_env(:jido_gralkor, :generalise_evaluate_fn, fn prompt ->
        send(test_pid, {:evaluate_prompt, prompt})

        {:ok,
         [
           %{
             action: "contradicts",
             hypothesis_index: 0,
             confidence: 0.9,
             content: "Eli prefers Friday launches.",
             existing_id: "existing-one"
           }
         ]}
      end)

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "generalisations",
                 content: "Eli: Let's launch on Friday.",
                 source_description: "captured"
               })

      assert_receive {:evaluate_prompt, prompt}
      assert prompt =~ "Eli sometimes chooses Friday."

      assert [%{id: episode_id, content: encoded}] =
               Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "generalisations"})

      assert {:ok, resulting, _plain} = Gralkor.Generalisation.decode(encoded)
      assert episode_id == resulting.id
      assert resulting.content == "Eli prefers Friday launches."
      assert resulting.generalises == ["existing-one"]
    end

    test "and the selected Lens determines whether the resulting generalisations are operator-local or global" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "generalisations",
          ontology: GeneralisationOntology,
          scope: :global,
          ingestion: Gralkor.Lens.Ingestion.Generalise
        ]
      ])

      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok, [%{content: "Eli prefers Friday launches.", confidence: 0.9}]}
      end)

      Application.put_env(:jido_gralkor, :generalise_evaluate_fn, fn _prompt ->
        {:ok,
         [
           %{
             action: "save",
             hypothesis_index: 0,
             confidence: 0.9,
             content: "Eli prefers Friday launches."
           }
         ]}
      end)

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "generalisations",
                 content: "Eli: Let's launch on Friday.",
                 source_description: "captured"
               })

      assert [%{lens: "generalisations", content: encoded}] =
               Gralkor.Lens.Storage.InMemory.episodes(:global)

      assert {:ok, resulting, _plain} = Gralkor.Generalisation.decode(encoded)
      assert resulting.content == "Eli prefers Friday launches."

      assert [] =
               Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "generalisations"})
    end

    test "and additions, replacements, and removals use the selected Lens's store" do
      start_supervised!(Gralkor.Lens.Storage.InMemory)
      Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "generalisations",
          ontology: GeneralisationOntology,
          scope: :operator,
          ingestion: Gralkor.Lens.Ingestion.Generalise
        ]
      ])

      store = %Gralkor.Lens.Store{
        operator_id: "operator-one",
        lens: Client.lens!("generalisations")
      }

      existing = %Gralkor.Generalisation{
        id: "existing-one",
        content: "Launches sometimes move.",
        level: 0,
        confidence: 0.6,
        generalises: []
      }

      assert :ok =
               Gralkor.Lens.Store.add(
                 store,
                 Gralkor.Generalisation.encode(existing),
                 "generalisation"
               )

      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok, [%{content: "Friday launches move.", confidence: 0.9}]}
      end)

      Application.put_env(:jido_gralkor, :generalise_evaluate_fn, fn _prompt ->
        {:ok,
         [
           %{
             action: "contradicts",
             hypothesis_index: 0,
             confidence: 0.9,
             content: "Friday launches move.",
             existing_id: "existing-one"
           }
         ]}
      end)

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "generalisations",
                 content: "The Friday launch moved.",
                 source_description: "captured"
               })

      assert [%{content: encoded}] =
               Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "generalisations"})

      assert {:ok, replacement, _plain} = Gralkor.Generalisation.decode(encoded)
      assert replacement.content == "Friday launches move."
      assert replacement.generalises == ["existing-one"]
    end
  end

  describe "where capture is configured to generalise a flushed transcript through another Lens" do
    test "then the generalising Lens receives the transcript independently of the Lens that captured it" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: RecordingIngestion
        ],
        [
          name: "generalisations",
          ontology: GeneralisationOntology,
          scope: :global,
          ingestion: GeneralisationRecordingIngestion
        ]
      ])

      start_supervised!(
        {Gralkor.CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
         retries: []}
      )

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations", "global"],
                 generalise_lens: "generalisations"
               )

      request_id = "request-generalise"

      agent = %{
        id: "operator-one",
        state: %{
          __memory__: plugin_state,
          __thread__: %{id: "session-generalise"},
          __strategy__: %{
            request_traces: %{request_id => %{events: [%{kind: :llm_completed, data: %{}}]}}
          },
          requests: %{
            request_id => %{query: "Let's launch Friday.", status: :pending, result: nil}
          },
          user_name: "Eli"
        }
      }

      signal = %Jido.Signal{
        id: "signal-generalise",
        source: "/test",
        type: "ai.request.completed",
        data: %{request_id: request_id, result: "Agreed."}
      }

      assert {:ok, :continue} = Plugin.handle_signal(signal, %{agent: agent})
      assert length(Gralkor.CaptureBuffer.turns_for("session-generalise")) == 1
      assert :ok = Gralkor.Client.Native.flush_and_await("session-generalise", 1_000)

      assert_receive {:ingested, %Ingest{lens: "observations", content: transcript},
                      observation_store}

      assert_receive {:generalised, %Ingest{lens: "generalisations", content: ^transcript},
                      generalisation_store}

      assert observation_store.lens.scope == :operator
      assert observation_store.lens.ontology == ObservationOntology
      assert observation_store.lens.ingestion == RecordingIngestion
      assert generalisation_store.lens.scope == :global
      assert generalisation_store.lens.ontology == GeneralisationOntology
      assert generalisation_store.lens.ingestion == GeneralisationRecordingIngestion
    end

    test "and each Lens retains its own ontology, scope, and ingestion process" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: RecordingIngestion
        ],
        [
          name: "generalisations",
          ontology: GeneralisationOntology,
          scope: :global,
          ingestion: GeneralisationRecordingIngestion
        ]
      ])

      assert %Gralkor.Lens{
               ontology: ObservationOntology,
               scope: :operator,
               ingestion: RecordingIngestion
             } = Client.lens!("observations")

      assert %Gralkor.Lens{
               ontology: GeneralisationOntology,
               scope: :global,
               ingestion: GeneralisationRecordingIngestion
             } = Client.lens!("generalisations")
    end
  end

  describe "if a Lens's ingestion process fails" do
    test "then ingestion returns that failure to the caller" do
      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: FailingIngestion
        ]
      ])

      assert {:error, :rejected} =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 content: "Do not store this.",
                 source_description: "test"
               })
    end

    test "and no implicit fallback write bypasses the selected process" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingStorage)

      Application.put_env(:jido_gralkor, :lenses, [
        [
          name: "observations",
          ontology: ObservationOntology,
          scope: :operator,
          ingestion: FailingIngestion
        ]
      ])

      assert {:error, :rejected} =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 content: "Do not store this.",
                 source_description: "test"
               })

      refute_receive {:add_episode, _, _, _}
    end
  end
end
