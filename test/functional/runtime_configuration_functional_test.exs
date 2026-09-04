defmodule Gralkor.RuntimeConfigurationFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  defmodule ConsumerAgent do
    use Jido.Agent,
      name: "runtime_configuration_consumer",
      default_plugins: false,
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Runtime Configuration Consumer",
           runtime_config: %{
             destinations: [],
             lenses: [],
             reflections: []
           }
         }}
      ]
  end

  defmodule InvalidConsumerAgent do
    use Jido.Agent,
      name: "invalid_runtime_configuration_consumer",
      default_plugins: false,
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Invalid Runtime Configuration Consumer",
           runtime_config: %{
             destinations: :not_a_list,
             lenses: [],
             reflections: []
           }
         }}
      ]
  end

  defmodule CustomLensConsumerAgent do
    use Jido.Agent,
      name: "custom_lens_runtime_configuration_consumer",
      default_plugins: false,
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Custom Lens Runtime Configuration Consumer",
           ingestion_lens: "runtime-observations",
           runtime_config: %{
             destinations: [%{name: "runtime-memory"}],
             lenses: [
               %{
                 name: "runtime-observations",
                 destination: "runtime-memory",
                 write: :append,
                 ingestion: RecordingIngestion
               }
             ],
             reflections: []
           }
         }}
      ]
  end

  defmodule ConsumerOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule EntityOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Entity do
      field(:value, :string)
    end
  end

  defmodule EpisodicOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Episodic do
      field(:value, :string)
    end
  end

  defmodule CommunityOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Community do
      field(:value, :string)
    end
  end

  defmodule PersonOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Person do
      field(:name, :string)
    end
  end

  defmodule RecordingIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(_request, store) do
      send(
        Application.fetch_env!(:jido_gralkor, :runtime_configuration_test_pid),
        {:runtime_ingestion, store.lens.destination.name}
      )

      :ok
    end
  end

  defmodule RecordingDestinationStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(destination, _operator_id, _query, _result_type, _max_results, _opts) do
      send(
        Application.fetch_env!(:jido_gralkor, :runtime_configuration_test_pid),
        {:runtime_search, destination.name}
      )

      {:ok, []}
    end

    @impl true
    def put_artefact(_, _, _, _), do: {:error, :unsupported}

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :unsupported}
  end

  defmodule RecordingLensStorage do
    @behaviour Gralkor.Lens.Storage

    @impl true
    def add_episode(_, _, _), do: {:error, :unsupported}

    @impl true
    def search(_, _, _), do: {:error, :unsupported}

    @impl true
    def replace_graph(store, graph) do
      send(
        Application.fetch_env!(:jido_gralkor, :runtime_configuration_test_pid),
        {:runtime_graph_replacement, store.lens.destination.name, graph}
      )

      :ok
    end
  end

  setup do
    keys = [:runtime_configuration_test_pid, :destination_storage, :lens_storage]
    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})
    Application.put_env(:jido_gralkor, :runtime_configuration_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:jido_gralkor, key)
        {key, value} -> Application.put_env(:jido_gralkor, key, value)
      end)
    end)

    :ok
  end

  describe "when a consumer starts a Jido agent with the Gralkor plugin" do
    test "then the plugin starts one Gralkor runtime under that agent" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent, id: "runtime-configuration-consumer", register_global: false}
        )

      assert {:ok, state} = Jido.AgentServer.state(agent_server)

      assert %{
               {:plugin, JidoGralkor.Plugin, JidoGralkor.Runtime} => %{
                 pid: runtime
               }
             } = state.children

      assert Process.alive?(runtime)
    end

    test "and that runtime owns the agent's runtime configuration" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent, id: "runtime-configuration-owner", register_global: false}
        )

      assert %{
               destinations: [],
               lenses: [],
               reflections: []
             } = JidoGralkor.Runtime.snapshot(agent_server)
    end

    test "and it installs package-owned structured definitions for the `operator` and `global` Destinations" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-packaged-destinations",
           register_global: false}
        )

      assert Enum.map(JidoGralkor.Runtime.destinations(agent_server), & &1.name) == [
               "operator",
               "global"
             ]
    end

    test "and it installs the package-owned `operator` Lens" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent, id: "runtime-configuration-packaged-lens", register_global: false}
        )

      assert %Gralkor.Lens{
               name: "operator",
               destination: %Gralkor.Destination{name: "operator"},
               ontology: Gralkor.DefaultOntology,
               ingestion: Gralkor.Lens.Ingestion.Store
             } = JidoGralkor.Runtime.lens!(agent_server, "operator")
    end

    test "and it installs package-owned structured definitions for the generalisations and ERL Reflections" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-packaged-reflections",
           register_global: false}
        )

      for name <- ["generalisations", "erl"] do
        assert %Gralkor.Reflection{
                 name: ^name,
                 chain_of_thought: %Gralkor.Reflection.ChainOfThought{
                   path: nil,
                   steps: [_ | _]
                 }
               } = JidoGralkor.Runtime.reflection!(agent_server, name)
      end
    end

    test "and it accepts an ingestion Lens defined only by that agent's runtime configuration" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: CustomLensConsumerAgent,
           id: "runtime-configuration-custom-ingestion-lens",
           register_global: false}
        )

      assert %Gralkor.Lens{
               name: "runtime-observations",
               destination: %Gralkor.Destination{name: "runtime-memory"},
               ingestion: RecordingIngestion
             } = JidoGralkor.Runtime.lens!(agent_server, "runtime-observations")
    end
  end

  describe "when a consumer replaces one agent's runtime configuration with complete valid Destination, Lens, and Reflection collections" do
    test "then the complete consumer configuration becomes active as one snapshot for that agent" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent, id: "runtime-configuration-replacement", register_global: false}
        )

      configuration = %{
        destinations: [%{name: "project"}],
        lenses: [
          %{
            name: "observations",
            destination: "project",
            write: :append,
            ingestion: Gralkor.Lens.Ingestion.Store,
            ontology: ConsumerOntology
          }
        ],
        reflections: [
          %{
            name: "review",
            outputs: [
              %{
                kind: :destination,
                destination: "project",
                ontology: ConsumerOntology
              }
            ],
            chain_of_thought: %{
              steps: [
                %{
                  label: "review",
                  directions: "Review the supplied evidence.",
                  output: %{"summary" => "string"}
                }
              ]
            }
          }
        ]
      }

      assert :ok = JidoGralkor.Runtime.replace(agent_server, configuration)
      assert configuration == JidoGralkor.Runtime.snapshot(agent_server)

      assert %Gralkor.Destination{name: "project"} =
               JidoGralkor.Runtime.destination!(agent_server, "project")

      assert %Gralkor.Lens{
               name: "observations",
               destination: %Gralkor.Destination{name: "project"},
               ontology: ConsumerOntology,
               ingestion: Gralkor.Lens.Ingestion.Store
             } = JidoGralkor.Runtime.lens!(agent_server, "observations")

      assert %Gralkor.Reflection{
               name: "review",
               outputs: [
                 %{
                   kind: :destination,
                   destination: %Gralkor.Destination{name: "project"},
                   ontology: ConsumerOntology
                 }
               ],
               chain_of_thought: %Gralkor.Reflection.ChainOfThought{
                 steps: [
                   %{
                     label: "review",
                     directions: "Review the supplied evidence.",
                     output: %{"summary" => "string"}
                   }
                 ]
               }
             } = JidoGralkor.Runtime.reflection!(agent_server, "review")
    end

    test "and another agent's runtime configuration remains unchanged" do
      first_agent =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent, id: "runtime-configuration-first-agent", register_global: false}
        )

      second_agent =
        start_supervised!(
          Supervisor.child_spec(
            {Jido.AgentServer,
             agent: ConsumerAgent,
             id: "runtime-configuration-second-agent",
             register_global: false},
            id: :runtime_configuration_second_agent
          )
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 first_agent,
                 destination_configuration("first-memory")
               )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 second_agent,
                 destination_configuration("second-memory")
               )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 first_agent,
                 destination_configuration("replacement-memory")
               )

      assert %Gralkor.Destination{name: "replacement-memory"} =
               JidoGralkor.Runtime.destination!(first_agent, "replacement-memory")

      assert %Gralkor.Destination{name: "second-memory"} =
               JidoGralkor.Runtime.destination!(second_agent, "second-memory")

      assert_raise ArgumentError, ~r/unknown_definition.*second-memory/, fn ->
        JidoGralkor.Runtime.destination!(first_agent, "second-memory")
      end
    end
  end

  describe "if a replacement is invalid" do
    test "then the call returns the validation failure" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-invalid-replacement",
           register_global: false}
        )

      assert {:error, {:invalid_collection, :destinations, :not_a_list}} =
               JidoGralkor.Runtime.replace(agent_server, %{
                 destinations: :not_a_list,
                 lenses: [],
                 reflections: []
               })
    end

    test "and that agent's previously active snapshot remains unchanged" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-preserved-replacement",
           register_global: false}
        )

      active = %{
        destinations: [%{name: "active"}],
        lenses: [],
        reflections: []
      }

      assert :ok = JidoGralkor.Runtime.replace(agent_server, active)

      assert {:error, {:invalid_collection, :lenses, :not_a_list}} =
               JidoGralkor.Runtime.replace(agent_server, %{
                 destinations: [],
                 lenses: :not_a_list,
                 reflections: []
               })

      assert active == JidoGralkor.Runtime.snapshot(agent_server)
    end
  end

  describe "if consumer configuration uses a name reserved by a package-owned definition" do
    test "then replacement fails without replacing the package-owned definition" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-reserved-package-name",
           register_global: false}
        )

      assert {:error, {:reserved_definition_name, :reflections, "erl"}} =
               JidoGralkor.Runtime.replace(agent_server, %{
                 destinations: [],
                 lenses: [],
                 reflections: [
                   %{
                     name: "erl",
                     outputs: [%{kind: :destination, destination: "global"}],
                     chain_of_thought: %{
                       steps: [
                         %{
                           label: "replace",
                           directions: "Replace the packaged definition.",
                           output: %{"replacement" => "string"}
                         }
                       ]
                     }
                   }
                 ]
               })

      packaged = JidoGralkor.Runtime.reflection!(agent_server, "erl")
      refute Enum.any?(packaged.chain_of_thought.steps, &(&1.label == "replace"))
    end
  end

  describe "if complete runtime configuration contains malformed or unknown definition fields" do
    test "then replacement fails identifying the definition and unknown fields" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-unknown-fields",
           register_global: false}
        )

      assert {:error, {:unknown_definition_fields, :destinations, "project", [:ontology]}} =
               JidoGralkor.Runtime.replace(agent_server, %{
                 destinations: [%{name: "project", ontology: ConsumerOntology}],
                 lenses: [],
                 reflections: []
               })
    end
  end

  describe "if the consumer supplies invalid durable configuration while starting an agent" do
    test "then the Gralkor plugin fails to start for that agent" do
      previous = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous) end)

      assert {:error, _reason} =
               Jido.AgentServer.start_link(
                 agent: InvalidConsumerAgent,
                 id: "runtime-configuration-invalid-start",
                 register_global: false
               )
    end
  end

  describe "when named ingestion begins" do
    test "and later named ingestion uses any subsequently installed Lens definition" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-current-ingestion",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 ingestion_configuration("first-memory")
               )

      assert :ok =
               Gralkor.Client.ingest(
                 agent_server,
                 ingestion_request("first-ingestion")
               )

      assert_receive {:runtime_ingestion, "first-memory"}

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 ingestion_configuration("second-memory")
               )

      assert :ok =
               Gralkor.Client.ingest(
                 agent_server,
                 ingestion_request("second-ingestion")
               )

      assert_receive {:runtime_ingestion, "second-memory"}
    end
  end

  describe "when a search begins" do
    test "and later search uses any subsequently installed Destination definitions" do
      Application.put_env(
        :jido_gralkor,
        :destination_storage,
        RecordingDestinationStorage
      )

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-current-search",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 destination_configuration("first-memory")
               )

      assert {:ok, []} =
               Gralkor.Client.search(
                 agent_server,
                 %Gralkor.Search{
                   operator_id: "operator-one",
                   query: "memory",
                   destinations: ["first-memory"]
                 }
               )

      assert_receive {:runtime_search, "first-memory"}

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 destination_configuration("second-memory")
               )

      assert {:ok, []} =
               Gralkor.Client.search(
                 agent_server,
                 %Gralkor.Search{
                   operator_id: "operator-one",
                   query: "memory",
                   destinations: ["second-memory"]
                 }
               )

      assert_receive {:runtime_search, "second-memory"}
    end

    test "then agentic memory search uses the targeted agent's Destination definitions" do
      Application.put_env(
        :jido_gralkor,
        :destination_storage,
        RecordingDestinationStorage
      )

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-agentic-search",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 destination_configuration("agent-memory")
               )

      assert {:ok, %{result: "[]"}} =
               JidoGralkor.Actions.MemorySearch.run(
                 %{query: "memory", destinations: ["agent-memory"], lenses: []},
                 %{agent_id: "operator-one", gralkor_runtime: agent_server}
               )

      assert_receive {:runtime_search, "agent-memory"}
    end
  end

  describe "when an agentic memory addition begins" do
    test "then it uses the targeted agent's current ingestion Lens" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent, id: "runtime-configuration-agentic-add", register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 ingestion_configuration("agent-memory")
               )

      assert {:ok, %{result: "Ingesting."}} =
               JidoGralkor.Actions.MemoryAdd.run(
                 %{
                   content: "runtime-directed insight",
                   source_kind: :document,
                   source_description: "functional"
                 },
                 %{
                   agent_id: "operator-one",
                   lens: "observations",
                   gralkor_runtime: agent_server
                 }
               )

      assert_receive {:runtime_ingestion, "agent-memory"}
    end
  end

  describe "when named graph replacement begins" do
    test "then it uses the replaceable Lens definition active for the targeted agent" do
      Application.put_env(:jido_gralkor, :lens_storage, RecordingLensStorage)

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-current-graph-replacement",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 replaceable_configuration("first-memory")
               )

      graph = %Gralkor.Graph{nodes: [], relationships: []}

      assert :ok =
               Gralkor.Client.replace(agent_server, %Gralkor.Replace{
                 operator_id: "operator-one",
                 lens: "topology",
                 graph: graph
               })

      assert_receive {:runtime_graph_replacement, "first-memory", ^graph}

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 replaceable_configuration("second-memory")
               )

      assert :ok =
               Gralkor.Client.replace(agent_server, %Gralkor.Replace{
                 operator_id: "operator-one",
                 lens: "topology",
                 graph: graph
               })

      assert_receive {:runtime_graph_replacement, "second-memory", ^graph}
    end
  end

  describe "when complete runtime configuration contains a replaceable Lens declaring `write: :replace_graph` and a Destination" do
    test "then replacement accepts the Lens for complete-graph replacement" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-replaceable-lens",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, %{
                 destinations: [%{name: "project"}],
                 lenses: [
                   %{
                     name: "project-topology",
                     destination: "project",
                     write: :replace_graph
                   }
                 ],
                 reflections: []
               })

      assert %Gralkor.Lens.Replaceable{
               name: "project-topology",
               destination: %Gralkor.Destination{name: "project"}
             } = JidoGralkor.Runtime.lens!(agent_server, "project-topology")
    end
  end

  describe "if a Lens definition combines appending and replacement fields" do
    test "then replacement fails identifying the incompatible Lens definition" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-incompatible-lens",
           register_global: false}
        )

      assert {:error, {:incompatible_lens_definition, "project-topology"}} =
               JidoGralkor.Runtime.replace(agent_server, %{
                 destinations: [%{name: "project"}],
                 lenses: [
                   %{
                     name: "project-topology",
                     destination: "project",
                     write: :replace_graph,
                     ingestion: RecordingIngestion
                   }
                 ],
                 reflections: []
               })
    end
  end

  describe "if an ontology declares a custom entity kind named `Entity`, `Episodic`, or `Community`" do
    test "then replacement fails identifying the entity kind reserved by Graphiti" do
      for {kind, ontology} <- [
            {"Entity", EntityOntology},
            {"Episodic", EpisodicOntology},
            {"Community", CommunityOntology}
          ] do
        agent_server =
          start_supervised!(
            Supervisor.child_spec(
              {Jido.AgentServer,
               agent: ConsumerAgent,
               id: "runtime-configuration-reserved-#{kind}",
               register_global: false},
              id: {:runtime_configuration_reserved, kind}
            )
          )

        assert {:error, {:reserved_entity_kind, ^kind}} =
                 JidoGralkor.Runtime.replace(agent_server, %{
                   destinations: [%{name: "project"}],
                   lenses: [
                     %{
                       name: "observations",
                       destination: "project",
                       write: :append,
                       ingestion: RecordingIngestion,
                       ontology: ontology
                     }
                   ],
                   reflections: []
                 })
      end
    end
  end

  describe "when an ontology declares custom entity kinds distinct from `Entity`, `Episodic`, and `Community`" do
    test "then those entity kinds remain eligible for runtime configuration" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-person-ontology",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, %{
                 destinations: [%{name: "project"}],
                 lenses: [
                   %{
                     name: "people",
                     destination: "project",
                     write: :append,
                     ingestion: RecordingIngestion,
                     ontology: PersonOntology
                   }
                 ],
                 reflections: []
               })

      assert %Gralkor.Lens{ontology: PersonOntology} =
               JidoGralkor.Runtime.lens!(agent_server, "people")
    end
  end

  defp ingestion_configuration(destination) do
    %{
      destinations: [%{name: destination}],
      lenses: [
        %{
          name: "observations",
          destination: destination,
          write: :append,
          ingestion: RecordingIngestion
        }
      ],
      reflections: []
    }
  end

  defp destination_configuration(destination) do
    %{
      destinations: [%{name: destination}],
      lenses: [],
      reflections: []
    }
  end

  defp replaceable_configuration(destination) do
    %{
      destinations: [%{name: destination}],
      lenses: [
        %{
          name: "topology",
          destination: destination,
          write: :replace_graph
        }
      ],
      reflections: []
    }
  end

  defp ingestion_request(id) do
    %Gralkor.Ingest{
      id: id,
      operator_id: "operator-one",
      lens: "observations",
      source_kind: :document,
      content: "runtime-configured memory",
      source_description: "functional"
    }
  end
end
