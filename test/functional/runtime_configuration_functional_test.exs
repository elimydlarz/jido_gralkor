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
                 ingestion: Gralkor.RuntimeConfigurationFunctionalTest.RecordingIngestion
               }
             ],
             reflections: []
           }
         }}
      ]
  end

  defmodule DurableConsumerAgent do
    use Jido.Agent,
      name: "durable_runtime_configuration_consumer",
      default_plugins: false,
      plugins: [
        {JidoGralkor.Plugin,
         %{
           agent_name: "Durable Runtime Configuration Consumer",
           runtime_config: %{
             destinations: [%{name: "durable-memory"}],
             lenses: [],
             reflections: []
           }
         }}
      ]
  end

  defmodule ConsumerSupervisor do
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      id = Keyword.fetch!(opts, :id)

      Supervisor.init(
        [
          {Jido.AgentServer, agent: DurableConsumerAgent, id: id, register_global: false}
        ],
        strategy: :one_for_one
      )
    end
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

  defmodule BlockingIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(_request, store) do
      test_pid = Application.fetch_env!(:jido_gralkor, :runtime_configuration_test_pid)
      send(test_pid, {:blocking_runtime_ingestion, self()})

      receive do
        :continue_runtime_ingestion ->
          send(test_pid, {:runtime_ingestion, store.lens.destination.name})
          :ok
      end
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

  defmodule SnapshotOutputStorage do
    @behaviour Gralkor.Destination.Storage

    @impl true
    def search(_, _, _, _, _, _), do: {:ok, []}

    @impl true
    def put_artefact(output, reflection_name, operator_id, artefact) do
      send(
        Application.fetch_env!(:jido_gralkor, :runtime_configuration_test_pid),
        {:runtime_reflection_delivery, output, reflection_name, operator_id, artefact}
      )

      :ok
    end

    @impl true
    def get_artefact(_, _, _, _), do: {:error, :not_found}
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
    keys = [:runtime_configuration_test_pid, :destination_storage, :lens_storage, :client]
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

    test "and that runtime supervises the agent's Reflection processing and output delivery" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-reflection-supervision",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(agent_server, reflection_configuration("reviews"))

      test_pid = self()
      release = make_ref()

      inference = fn _request ->
        send(test_pid, {:supervised_reflection_started, self()})

        receive do
          {^release, :continue} -> {:ok, %{output: %{"summary" => "complete"}}}
        end
      end

      assert {:ok, "supervised-reflection"} =
               Gralkor.Client.reflect(
                 agent_server,
                 "review",
                 reflection_invocation("supervised-reflection"),
                 &send(test_pid, {:supervised_reflection_callback, &1}),
                 inference: inference,
                 storage: SnapshotOutputStorage
               )

      assert_receive {:supervised_reflection_started, worker}
      assert Process.alive?(worker)
      send(worker, {release, :continue})
      assert_receive {:supervised_reflection_callback, %{outcome: :delivered}}
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
                   steps: [_ | _]
                 }
               } = JidoGralkor.Runtime.reflection!(agent_server, name)
      end
    end

    test "and it installs the complete consumer configuration supplied when the agent started" do
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

    test "and the packaged Destinations, Lens, and Reflections remain active" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-packaged-after-replacement",
           register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 destination_configuration("consumer-memory")
               )

      assert %Gralkor.Destination{name: "operator"} =
               JidoGralkor.Runtime.destination!(agent_server, "operator")

      assert %Gralkor.Destination{name: "global"} =
               JidoGralkor.Runtime.destination!(agent_server, "global")

      assert %Gralkor.Lens{name: "operator"} =
               JidoGralkor.Runtime.lens!(agent_server, "operator")

      assert %Gralkor.Reflection{name: "generalisations"} =
               JidoGralkor.Runtime.reflection!(agent_server, "generalisations")

      assert %Gralkor.Reflection{name: "erl"} =
               JidoGralkor.Runtime.reflection!(agent_server, "erl")
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

    test "and the call returns only after the replacement is active" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-synchronous-replacement",
           register_global: false}
        )

      configuration = destination_configuration("active-on-return")
      assert :ok = JidoGralkor.Runtime.replace(agent_server, configuration)
      assert JidoGralkor.Runtime.snapshot(agent_server) == configuration

      assert %Gralkor.Destination{name: "active-on-return"} =
               JidoGralkor.Runtime.destination!(agent_server, "active-on-return")
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

  describe "if an optional ontology field is explicitly false" do
    test "then validation rejects false as the invalid ontology value" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-false-ontology",
           register_global: false}
        )

      assert {:error, {:invalid_lens_ontology, "observations", false}} =
               JidoGralkor.Runtime.replace(agent_server, false_ontology_configuration())
    end

    test "and an atom-keyed false value is not replaced by a string-keyed value from the same definition" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent,
           id: "runtime-configuration-atom-false-ontology",
           register_global: false}
        )

      configuration = false_ontology_configuration()
      [lens] = configuration.lenses

      assert {:error, {:invalid_lens_ontology, "observations", false}} =
               JidoGralkor.Runtime.replace(agent_server, %{
                 configuration
                 | lenses: [Map.put(lens, "ontology", ConsumerOntology)]
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

    test "and no part of the invalid configuration becomes active" do
      previous = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous) end)
      before = runtime_owner_names()

      assert {:error, _reason} =
               Jido.AgentServer.start_link(
                 agent: InvalidConsumerAgent,
                 id: "runtime-configuration-no-partial-invalid-start",
                 register_global: false
               )

      assert runtime_owner_names() == before
    end
  end

  describe "when a consuming agent is restarted under consumer supervision" do
    test "then the consumer starts the agent with its current complete durable configuration" do
      supervisor =
        start_supervised!({ConsumerSupervisor, id: "runtime-configuration-consumer-restart"})

      original_agent = supervised_agent(supervisor)
      Process.exit(original_agent, :kill)

      replacement_agent = await_replacement_agent(supervisor, original_agent)

      assert %{
               destinations: [%{name: "durable-memory"}],
               lenses: [],
               reflections: []
             } = JidoGralkor.Runtime.snapshot(replacement_agent)

      assert %Gralkor.Destination{name: "durable-memory"} =
               JidoGralkor.Runtime.destination!(replacement_agent, "durable-memory")
    end

    test "and the restarted plugin installs that configuration before accepting memory work" do
      replacement_agent = restart_consuming_agent("runtime-configuration-restart-install")

      assert %{
               destinations: [%{name: "durable-memory"}],
               lenses: [],
               reflections: []
             } = JidoGralkor.Runtime.snapshot(replacement_agent)

      assert %Gralkor.Destination{name: "durable-memory"} =
               JidoGralkor.Runtime.destination!(replacement_agent, "durable-memory")
    end
  end

  describe "if the Gralkor plugin runtime terminates unexpectedly" do
    test "then its linked AgentServer terminates" do
      supervisor =
        start_supervised!({ConsumerSupervisor, id: "runtime-configuration-runtime-restart"})

      original_agent = supervised_agent(supervisor)
      original_monitor = Process.monitor(original_agent)
      {:ok, state} = Jido.AgentServer.state(original_agent)

      %{pid: runtime} =
        Map.fetch!(state.children, {:plugin, JidoGralkor.Plugin, JidoGralkor.Runtime})

      Process.exit(runtime, :unexpected_runtime_failure)

      assert_receive {:DOWN, ^original_monitor, :process, ^original_agent,
                      :unexpected_runtime_failure}

      replacement_agent = await_replacement_agent(supervisor, original_agent)

      assert %{
               destinations: [%{name: "durable-memory"}],
               lenses: [],
               reflections: []
             } = JidoGralkor.Runtime.snapshot(replacement_agent)
    end

    test "and the consumer supervisor starts a replacement AgentServer" do
      {_original_agent, replacement_agent} =
        restart_after_runtime_failure("runtime-configuration-supervisor-replacement")

      assert Process.alive?(replacement_agent)
    end

    test "and the replacement agent receives the consumer's current durable configuration" do
      {_original_agent, replacement_agent} =
        restart_after_runtime_failure("runtime-configuration-durable-replacement")

      assert %{
               destinations: [%{name: "durable-memory"}],
               lenses: [],
               reflections: []
             } = JidoGralkor.Runtime.snapshot(replacement_agent)
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

  describe "when a named Reflection submission is admitted" do
    test "then its background work retains the Reflection definition active at admission" do
      {first_output, _second_output} = reflection_snapshot_outputs("retained-reflection")
      assert first_output.destination.name == "first-reviews"
    end

    test "and later submission uses any subsequently installed Reflection definition" do
      {_first_output, second_output} = reflection_snapshot_outputs("later-reflection")
      assert second_output.destination.name == "second-reviews"
    end
  end

  describe "when a search begins" do
    test "then its selected Lenses and Destinations resolve from one runtime snapshot" do
      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: ConsumerAgent, id: "runtime-configuration-atomic-search", register_global: false}
        )

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 ingestion_configuration("project")
               )

      assert {[%Gralkor.Lens{name: "observations"}], [%Gralkor.Destination{name: "project"}]} =
               JidoGralkor.Runtime.resolve_search!(
                 agent_server,
                 ["observations"],
                 ["project"]
               )
    end

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

  end

 describe "when a runtime-targeted operation cannot reach its owning AgentServer runtime" do
    test "then it fails without falling back to application compatibility configuration" do
      Application.put_env(:jido_gralkor, :destination_storage, RecordingDestinationStorage)

      dead_owner = spawn(fn -> :ok end)
      monitor = Process.monitor(dead_owner)
      assert_receive {:DOWN, ^monitor, :process, ^dead_owner, :normal}

      assert_raise ArgumentError, ~r/Gralkor runtime unavailable/, fn ->
        JidoGralkor.Actions.MemorySearch.run(
          %{query: "memory", destinations: ["global"], lenses: []},
          %{agent_id: "operator-one", gralkor_runtime: dead_owner}
        )
      end

      refute_receive {:runtime_search, _destination}
    end

    test "then targeted capture fails without invoking the compatibility capture arity" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.InMemory)
      Gralkor.Client.InMemory.set_capture(:ok)

      dead_owner = spawn(fn -> :ok end)
      monitor = Process.monitor(dead_owner)
      assert_receive {:DOWN, ^monitor, :process, ^dead_owner, :normal}

      assert_raise ArgumentError, ~r/Gralkor runtime unavailable/, fn ->
        Gralkor.Client.capture(
          dead_owner,
          "runtime-unavailable-capture",
          "operator-one",
          "Runtime Configuration Consumer",
          "Eli",
          [Gralkor.Message.new("user", "must not cross configuration boundaries")],
          "operator",
          []
        )
      end

      assert Gralkor.Client.InMemory.captures() == []
    end
  end

  describe "if a runtime-targeted operation is given anything other than an owning AgentServer PID" do
    test "then it fails identifying that the target must be a PID" do
      assert_raise ArgumentError, ~r/runtime target must be an owning AgentServer PID/, fn ->
        JidoGralkor.Runtime.snapshot(:registered_agent_name)
      end
    end
  end

  describe "when a selected-Lens turn is buffered for capture" do
    test "then its eventual ingestion resolves the Lens through the targeted agent's runtime configuration" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      start_supervised!(
        {Gralkor.CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
         retries: []}
      )

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: CustomLensConsumerAgent,
           id: "runtime-configuration-captured-ingestion",
           register_global: false}
        )

      assert :ok =
               Gralkor.Client.capture(
                 agent_server,
                 "runtime-capture-session",
                 "operator-one",
                 "Runtime Configuration Consumer",
                 "Eli",
                 [Gralkor.Message.new("user", "Remember this runtime-configured fact.")],
                 "runtime-observations",
                 []
               )

      assert :ok = Gralkor.Client.Native.flush_and_await("runtime-capture-session", 1_000)
      assert_receive {:runtime_ingestion, "runtime-memory"}
    end

    test "then a scheduled ingestion retains its resolved Lens after the targeted agent terminates" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
      test_pid = self()
      runtime_callback = Gralkor.Application.build_lens_flush_callback()

      lens_flush_callback = fn operator_id,
                               agent_name,
                               user_name,
                               lens,
                               turns,
                               ingestion_id,
                               runtime_owner ->
        send(test_pid, {:lens_flush_worker_ready, self()})

        receive do
          :continue_lens_flush ->
            runtime_callback.(
              operator_id,
              agent_name,
              user_name,
              lens,
              turns,
              ingestion_id,
              runtime_owner
            )
        end
      end

      start_supervised!(
        {Gralkor.CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: lens_flush_callback,
         lens_resolver: fn runtime_owner, names ->
           {:ok, JidoGralkor.Runtime.lenses!(runtime_owner, names)}
         end,
         retries: []}
      )

      agent_server =
        start_supervised!(
          {Jido.AgentServer,
           agent: CustomLensConsumerAgent,
           id: "runtime-configuration-captured-after-agent-stop",
           register_global: false}
        )

      assert :ok =
               Gralkor.Client.capture(
                 agent_server,
                 "runtime-capture-after-stop",
                 "operator-one",
                 "Runtime Configuration Consumer",
                 "Eli",
                 [Gralkor.Message.new("user", "Retain the resolved Lens.")],
                 "runtime-observations",
                 []
               )

      assert :ok = Gralkor.Client.Native.flush("runtime-capture-after-stop")
      assert_receive {:lens_flush_worker_ready, worker}

      assert :ok =
               JidoGralkor.Runtime.replace(
                 agent_server,
                 ingestion_configuration("replacement-memory")
               )

      assert :ok = GenServer.stop(agent_server, :normal)
      send(worker, :continue_lens_flush)
      assert_receive {:runtime_ingestion, "runtime-memory"}
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

  defp reflection_snapshot_outputs(id) do
    Application.put_env(:jido_gralkor, :destination_storage, SnapshotOutputStorage)
    first_id = "#{id}-first"
    second_id = "#{id}-second"

    agent_server =
      start_supervised!(
        {Jido.AgentServer, agent: ConsumerAgent, id: "#{id}-agent", register_global: false}
      )

    assert :ok =
             JidoGralkor.Runtime.replace(
               agent_server,
               reflection_configuration("first-reviews")
             )

    test_pid = self()
    release = make_ref()

    blocked_inference = fn _request ->
      send(test_pid, {:runtime_snapshot_started, self()})

      receive do
        {^release, :continue} -> {:ok, %{output: %{"summary" => "first"}}}
      end
    end

    callback = &send(test_pid, {:runtime_reflection_callback, &1})

    assert {:ok, ^first_id} =
             Gralkor.Client.reflect(
               agent_server,
               "review",
               reflection_invocation(first_id),
               callback,
               inference: blocked_inference
             )

    assert_receive {:runtime_snapshot_started, blocked_process}

    assert :ok =
             JidoGralkor.Runtime.replace(
               agent_server,
               reflection_configuration("second-reviews")
             )

    send(blocked_process, {release, :continue})

    assert_receive {:runtime_reflection_delivery, first_output, "review", _, first_artefact}
    assert_receive {:runtime_reflection_callback, %{artefact: ^first_artefact}}

    assert {:ok, ^second_id} =
             Gralkor.Client.reflect(
               agent_server,
               "review",
               reflection_invocation(second_id),
               callback,
               inference: fn _ -> {:ok, %{output: %{"summary" => "second"}}} end
             )

    assert_receive {:runtime_reflection_delivery, second_output, "review", _, second_artefact}
    assert_receive {:runtime_reflection_callback, %{artefact: ^second_artefact}}
    {first_output, second_output}
  end

  defp reflection_configuration(destination) do
    %{
      destinations: [%{name: destination}],
      lenses: [],
      reflections: [
        %{
          name: "review",
          outputs: [%{kind: :destination, destination: destination}],
          chain_of_thought: %{
            steps: [
              %{
                label: "review",
                directions: "Review.",
                output: %{"summary" => "string"}
              }
            ]
          }
        }
      ]
    }
  end

  defp reflection_invocation(id) do
    %{id: id, operator_id: "operator-one", invocation_context: %{}, representations: []}
  end

  defp empty_runtime_configuration,
    do: %{destinations: [], lenses: [], reflections: []}

  defp valid_runtime_definition(:destinations, name), do: %{name: name}

  defp valid_runtime_definition(:lenses, name) do
    %{
      name: name,
      destination: "global",
      write: :append,
      ingestion: RecordingIngestion
    }
  end

  defp valid_runtime_definition(:reflections, name) do
    %{
      name: name,
      outputs: [%{kind: :destination, destination: "global"}],
      chain_of_thought: %{
        steps: [
          %{
            label: "review",
            directions: "Review.",
            output: %{"summary" => "string"}
          }
        ]
      }
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

  defp supervised_agent(supervisor) do
    [{_id, agent, :worker, [Jido.AgentServer]}] = Supervisor.which_children(supervisor)
    agent
  end

  defp await_replacement_agent(supervisor, original_agent, attempts \\ 50)

  defp await_replacement_agent(supervisor, original_agent, 0) do
    agent = supervised_agent(supervisor)
    refute agent == original_agent
    agent
  end

  defp await_replacement_agent(supervisor, original_agent, attempts) do
    case Supervisor.which_children(supervisor) do
      [{_id, agent, :worker, [Jido.AgentServer]}]
      when is_pid(agent) and agent != original_agent ->
        agent

      _ ->
        Process.sleep(10)
        await_replacement_agent(supervisor, original_agent, attempts - 1)
    end
  end
end
