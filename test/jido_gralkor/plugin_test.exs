defmodule JidoGralkor.PluginTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Gralkor.Client.InMemory
  alias Jido.Signal
  alias JidoGralkor.Plugin

  defmodule LensOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  defmodule PluginTestJido do
    use Jido, otp_app: :jido_gralkor
  end

  defmodule RecordToolContext do
    use Jido.Action, name: "record_tool_context", schema: []

    def run(params, _context),
      do: {:ok, %{recorded_tool_context: Map.get(params, :tool_context)}}
  end

  defmodule ServerAgent do
    use Jido.Agent,
      name: "plugin_test_server_agent",
      default_plugins: %{__memory__: false},
      plugins: [
        {JidoGralkor.Plugin, %{agent_name: "Susu"}}
      ],
      signal_routes: [
        {"ai.react.query", RecordToolContext}
      ]
  end

  setup_all do
    {:ok, _applications} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  setup do
    InMemory.reset()
    start_supervised!({Jido, name: PluginTestJido, otp_app: :jido_gralkor})

    start_supervised!(
      {JidoGralkor.Runtime, owner: self(), configuration: runtime_configuration()}
    )

    :ok
  end

  defp agent(id, opts) do
    thread_id = Keyword.get(opts, :thread_id, "thr-default")
    request_traces = Keyword.get(opts, :request_traces, %{})
    requests = Keyword.get(opts, :requests, %{})
    agent_name = Keyword.get(opts, :agent_name, "TestAgent")

    state =
      %{
        __strategy__: %{request_traces: request_traces, config: %{}},
        requests: requests,
        __memory__: %{agent_name: agent_name}
      }
      |> maybe_put(:__thread__, if(thread_id, do: %{id: thread_id}, else: nil))

    %{id: id, state: state}
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp context(agent) do
    registry = Jido.registry_name(PluginTestJido)

    case Registry.lookup(registry, agent.id) do
      [] -> {:ok, _owner} = Registry.register(registry, agent.id, %{})
      [{owner, _value}] when owner == self() -> :ok
    end

    %{agent: agent, jido_instance: PluginTestJido, partition: nil}
  end

  defp start_server_agent(id) do
    {:ok, pid} = Jido.start_agent(PluginTestJido, ServerAgent, id: id)
    pid
  end

  describe "when a consumer reads the plugin's advertised actions" do
    test "then memory search, memory add, build indices, and build communities are exposed in that order for the consumer to pass as agent tools" do
      assert Plugin.actions() == [
               JidoGralkor.Actions.MemorySearch,
               JidoGralkor.Actions.MemoryAdd,
               JidoGralkor.Actions.MemoryBuildIndices,
               JidoGralkor.Actions.MemoryBuildCommunities
             ]
    end
  end

  describe "when a consumer reads the plugin's advertised identity and ownership" do
    test "then it is named `gralkor`" do
      assert Plugin.name() == "gralkor"
    end

    test "and it advertises the memory capability" do
      assert Plugin.capabilities() == [:memory]
    end

    test "and it owns the `:__memory__` plugin-state slot" do
      assert Plugin.state_key() == :__memory__
    end

    test "and it is singleton" do
      assert Plugin.singleton?()
    end
  end

  describe "when a consuming AgentServer requests the plugin's child specification" do
    test "then the plugin declares one Gralkor runtime child owned by that AgentServer" do
      assert %{
               id: JidoGralkor.Runtime,
               start:
                 {JidoGralkor.Runtime, :start_link,
                  [
                    [
                      owner: owner,
                      configuration: %{destinations: [], lenses: [], reflections: []}
                    ]
                  ]}
             } = Plugin.child_spec(%{})

      assert owner == self()
    end

    test "and the child receives the complete runtime configuration supplied to the plugin" do
      configuration = %{
        destinations: [[name: "notes"]],
        lenses: [[name: "observations", destination: "notes"]],
        reflections: [[name: "summarise"]]
      }

      assert %{
               start:
                 {JidoGralkor.Runtime, :start_link,
                  [[owner: owner, configuration: ^configuration]]}
             } = Plugin.child_spec(runtime_config: configuration)

      assert owner == self()
    end
  end

  describe "when a consuming AgentServer requests the plugin's child specification > where runtime configuration is omitted" do
    test "then the child receives empty consumer Destination, Lens, and Reflection collections" do
      assert %{
               start:
                 {JidoGralkor.Runtime, :start_link,
                  [
                    [
                      owner: _owner,
                      configuration: %{destinations: [], lenses: [], reflections: []}
                    ]
                  ]}
             } = Plugin.child_spec(%{})
    end
  end

  describe "when a consumer agent mounts the plugin" do
    test "then the expanded routes resolve with no conflicts against the host agent" do
      instance = Jido.Plugin.Instance.new({Plugin, %{agent_name: "Test"}})
      routes = Jido.Plugin.Routes.expand_routes(instance)
      assert {:ok, _resolved} = Jido.Plugin.Routes.detect_conflicts(routes)
    end
  end

  describe "when mount is given a non-blank agent name" do
    test "then it returns plugin state carrying that agent name" do
      assert {:ok, %{agent_name: "Susu"}} =
               Plugin.mount(%{id: "user-1", state: %{}},
                 agent_name: "Susu"
               )
    end
  end

  describe "if mount is given no agent name" do
    test "then it raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Plugin.mount(%{id: "user-1", state: %{}}, [])
      end
    end
  end

  describe "if mount is given a blank agent name" do
    test "then it raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        Plugin.mount(%{id: "user-1", state: %{}}, agent_name: "  ")
      end
    end
  end

  describe "if mount's runtime configuration is invalid" do
    test "then it raises an ArgumentError identifying the invalid configuration" do
      invalid = %{
        destinations: [],
        lenses: [
          %{
            name: "stray",
            destination: "absent",
            ingestion: Gralkor.Lens.Ingestion.Store
          }
        ],
        reflections: []
      }

      assert_raise ArgumentError,
                   ~r/invalid Gralkor runtime configuration.*"stray".*"absent"/,
                   fn ->
                     Plugin.mount(%{id: "operator-one", state: %{}},
                       agent_name: "Susu",
                       runtime_config: invalid
                     )
                   end
    end
  end

  describe "when mount selects an ingestion Lens" do
    test "then the selected Lens name is stored on the plugin state without copying its definition" do
      configure_lenses()

      assert {:ok,
              %{
                agent_name: "Susu",
                ingestion_lens: "observations"
              }} =
               Plugin.mount(%{id: "operator-one", state: %{}},
                 agent_name: "Susu",
                 ingestion_lens: "observations",
                 runtime_config: runtime_configuration()
               )
    end
  end

  describe "when mount selects an ingestion Lens > where the selected Lens is packaged" do
    test "then mounting accepts the Lens" do
      assert {:ok,
              %{
                agent_name: "Susu",
                ingestion_lens: "personal-chat"
              }} =
               Plugin.mount(%{id: "operator-one", state: %{}},
                 agent_name: "Susu",
                 ingestion_lens: "personal-chat"
               )
    end
  end

  describe "when mount selects an ingestion Lens > where the selected Lens is declared by that mount" do
    test "then mounting accepts the Lens" do
      assert {:ok,
              %{
                agent_name: "Susu",
                ingestion_lens: "observations"
              }} =
               Plugin.mount(%{id: "operator-one", state: %{}},
                 agent_name: "Susu",
                 ingestion_lens: "observations",
                 runtime_config: runtime_configuration()
               )
    end
  end

  describe "when mount selects an ingestion Lens > if the ingestion Lens is unknown" do
    test "then mounting raises an ArgumentError identifying the unknown Lens" do
      configure_lenses()

      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Plugin.mount(%{id: "operator-one", state: %{}},
          agent_name: "Susu",
          ingestion_lens: "missing"
        )
      end
    end
  end

  describe "when mount selects an ingestion Lens > if the ingestion Lens is retired" do
    test "then mounting raises an ArgumentError naming `personal-chat` as its replacement" do
      for retired <- ["operator", "default"] do
        assert_raise ArgumentError, ~r/"#{retired}" was retired.*"personal-chat"/, fn ->
          Plugin.mount(%{id: "operator-one", state: %{}},
            agent_name: "Susu",
            ingestion_lens: retired
          )
        end
      end
    end
  end

  describe "when mount selects an ingestion Lens > if the Lens exists only in the application compatibility registry" do
    test "then mounting raises an ArgumentError identifying the unknown Lens" do
      configure_lenses()

      assert_raise ArgumentError, ~r/unknown Lens "observations"/, fn ->
        Plugin.mount(%{id: "operator-one", state: %{}},
          agent_name: "Susu",
          ingestion_lens: "observations"
        )
      end
    end
  end

  describe "when mount selects an ingestion Lens > if the removed `:default_lens` option is supplied" do
    test "then mounting raises an ArgumentError identifying `:ingestion_lens` as its replacement" do
      configure_lenses()

      assert_raise ArgumentError, ~r/default_lens.*ingestion_lens/, fn ->
        Plugin.mount(%{id: "operator-one", state: %{}},
          agent_name: "Susu",
          default_lens: "observations"
        )
      end
    end
  end

  describe "if mount receives the removed `:search_destinations` option" do
    test "then mounting raises an ArgumentError identifying MemorySearch's per-search `destinations` selector as its replacement" do
      assert_raise ArgumentError,
                   ~r/search_destinations.*MemorySearch.*per-search.*destinations/,
                   fn ->
                     Plugin.mount(%{id: "operator-one", state: %{}},
                       agent_name: "Susu",
                       search_destinations: ["memory"]
                     )
                   end
    end
  end

  describe "if mount receives the removed `capture_destination` option" do
    test "then mounting raises an ArgumentError saying capture was removed in 18.0.0 and directing the consumer to remember its own chat record with `Gralkor.Client.ingest/2` through a Lens" do
      for capture_destination <- ["personal", nil] do
        error =
          assert_raise ArgumentError, fn ->
            Plugin.mount(%{id: "operator-one", state: %{}},
              agent_name: "Susu",
              capture_destination: capture_destination
            )
          end

        assert Exception.message(error) =~ "capture was removed in 18.0.0"
        assert Exception.message(error) =~ "own chat record"
        assert Exception.message(error) =~ "Gralkor.Client.ingest/2 through a Lens"
      end
    end
  end

  describe "when an agent turn begins > while a thread has committed to agent state" do
    test "then the session id planted on the signal's tool context is that committed thread's id rather than one the plugin mints" do
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      assert {:ok, {:continue, %Signal{data: data}}} =
               Plugin.handle_signal(signal, context(agent("user-abc", thread_id: "thr-xyz")))

      assert data.tool_context.session_id == "thr-xyz"
    end

    test "and the mounted agent name is planted on the tool context beside it" do
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      assert {:ok, {:continue, %Signal{data: data}}} =
               Plugin.handle_signal(signal, context(agent("user-abc", thread_id: "thr-xyz")))

      assert data.tool_context.agent_name == "TestAgent"
    end

    test "and the owning AgentServer is planted as the Gralkor runtime target" do
      pid = start_server_agent("server-operator-query")

      :sys.replace_state(pid, fn server_state ->
        put_in(server_state.agent.state[:__thread__], Jido.Thread.new(id: "thr-xyz"))
      end)

      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      assert {:ok, %{state: %{recorded_tool_context: tool_context}}} =
               Jido.AgentServer.call(pid, signal)

      assert tool_context.gralkor_runtime == pid
    end

    test "and no recall is issued on the plugin's own initiative" do
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      Plugin.handle_signal(signal, context(agent("user-abc", thread_id: "thr-xyz")))

      assert InMemory.recalls() == []
    end

    test "and the user's query is left untouched on the signal" do
      signal = Signal.new!("ai.react.query", %{query: "hello"}, source: "/test")

      assert {:ok, {:continue, %Signal{data: data}}} =
               Plugin.handle_signal(signal, context(agent("user-abc", thread_id: "thr-xyz")))

      assert data.query == "hello"
    end

    test "and unrelated incoming tool-context fields remain alongside fields planted by the plugin" do
      signal =
        Signal.new!(
          "ai.react.query",
          %{query: "hello", tool_context: %{tenant: "tenant-one"}},
          source: "/test"
        )

      assert {:ok, {:continue, %Signal{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, context(agent("user-abc", thread_id: "thr-xyz")))

      assert tool_context.tenant == "tenant-one"
      assert tool_context.session_id == "thr-xyz"
      assert tool_context.agent_name == "TestAgent"
    end
  end

  describe "when an agent turn begins > while a thread has committed to agent state > where the incoming tool context selects a Lens" do
    test "then the selected Lens is validated and kept on the tool context" do
      plugin_state = lens_plugin_state()

      signal =
        Signal.new!(
          "ai.react.query",
          %{query: "hi", tool_context: %{lens: "notes"}},
          source: "/test"
        )

      lens_agent =
        agent("operator-one", thread_id: "thread-one")
        |> put_in([:state, :__memory__], plugin_state)

      assert {:ok, {:continue, %Signal{data: %{tool_context: %{lens: "notes"}}}}} =
               Plugin.handle_signal(signal, context(lens_agent))
    end
  end

  describe "when an agent turn begins > while a thread has committed to agent state > where the incoming tool context selects a Lens > if the Lens is unknown or invalid" do
    test "then the callback raises identifying the invalid Lens" do
      plugin_state = lens_plugin_state()

      lens_agent =
        agent("operator-one", thread_id: "thread-one")
        |> put_in([:state, :__memory__], plugin_state)

      for {invalid, message} <- [
            {"missing", ~r/unknown_definition, :lenses, "missing"/},
            {42, ~r/invalid Lens 42/}
          ] do
        signal =
          Signal.new!("ai.react.query", %{query: "hi", tool_context: %{lens: invalid}},
            source: "/test"
          )

        assert_raise ArgumentError, message, fn ->
          Plugin.handle_signal(signal, context(lens_agent))
        end
      end
    end
  end

  describe "when an agent turn begins > while a thread has committed to agent state > where the incoming tool context explicitly selects no Lens" do
    test "then the tool context keeps that empty Lens selection" do
      plugin_state = lens_plugin_state()

      signal =
        Signal.new!(
          "ai.react.query",
          %{query: "hi", tool_context: %{lens: nil}},
          source: "/test"
        )

      query_agent =
        agent("operator-one", thread_id: "thread-one")
        |> put_in([:state, :__memory__], plugin_state)

      assert {:ok, {:continue, %Signal{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, context(query_agent))

      assert Map.fetch(tool_context, :lens) == {:ok, nil}
    end
  end

  describe "when an agent turn begins > while no thread has committed to agent state" do
    test "then the mounted agent name and Gralkor runtime target are planted on the tool context, with no session id" do
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      assert {:ok, {:continue, %Signal{data: data}}} =
               Plugin.handle_signal(signal, context(agent("user-abc", thread_id: nil)))

      assert data.tool_context.agent_name == "TestAgent"
      assert data.tool_context.gralkor_runtime == self()
      refute Map.has_key?(data.tool_context, :session_id)
    end

    test "and no recall is issued on the plugin's own initiative" do
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      Plugin.handle_signal(signal, context(agent("user-abc", thread_id: nil)))

      assert InMemory.recalls() == []
    end
  end

  describe "when an agent turn begins > where the plugin was mounted with an ingestion Lens > while a thread has committed to agent state" do
    test "then the Lens selection and committed session id are planted on the tool context beside the agent name" do
      plugin_state = lens_plugin_state()
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      lens_agent =
        agent("operator-one", thread_id: "thread-one")
        |> put_in([:state, :__memory__], plugin_state)

      assert {:ok, {:continue, %Signal{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, context(lens_agent))

      assert tool_context == %{
               agent_name: "Susu",
               gralkor_runtime: self(),
               lens: "observations",
               session_id: "thread-one"
             }
    end
  end

  describe "when an agent turn begins > where the plugin was mounted with an ingestion Lens > while no thread has committed to agent state" do
    test "then the Lens selection is planted on the tool context beside the agent name without a session id" do
      plugin_state = lens_plugin_state()
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      lens_agent =
        agent("operator-one", thread_id: nil)
        |> put_in([:state, :__memory__], plugin_state)

      assert {:ok, {:continue, %Signal{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, context(lens_agent))

      assert tool_context == %{
               agent_name: "Susu",
               gralkor_runtime: self(),
               lens: "observations"
             }
    end
  end

  describe "when a signal of any other type arrives" do
    test "then the plugin lets the signal continue untouched" do
      ag = agent("user-other", thread_id: "thr-other")
      signal = Signal.new!("ai.llm.delta", %{token: "x"}, source: "/test")

      assert {:ok, :continue} = Plugin.handle_signal(signal, context(ag))
    end

    test "and nothing is recalled" do
      ag = agent("user-other", thread_id: "thr-other")
      signal = Signal.new!("ai.llm.delta", %{token: "x"}, source: "/test")
      Plugin.handle_signal(signal, context(ag))
      assert InMemory.recalls() == []
    end
  end

  describe "if a memory signal hook cannot identify its owning AgentServer" do
    test "then the callback raises identifying the missing owner" do
      ag =
        agent("unregistered-operator", thread_id: "thread-one")
        |> put_in([:state, :__memory__], lens_plugin_state())

      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      for hook_context <- [
            %{agent: ag, jido_instance: nil, partition: nil},
            %{agent: ag, jido_instance: PluginTestJido, partition: nil}
          ] do
        assert_raise ArgumentError, ~r/cannot identify its owning Jido.AgentServer/, fn ->
          Plugin.handle_signal(signal, hook_context)
        end
      end
    end
  end

  defp lens_plugin_state do
    configure_lenses()

    {:ok, plugin_state} =
      Plugin.mount(%{id: "operator-one", state: %{}},
        agent_name: "Susu",
        ingestion_lens: "observations",
        runtime_config: runtime_configuration()
      )

    plugin_state
  end

  defp configure_lenses do
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)

    on_exit(fn ->
      if previous_lenses,
        do: Application.put_env(:jido_gralkor, :lenses, previous_lenses),
        else: Application.delete_env(:jido_gralkor, :lenses)

      if previous_destinations,
        do: Application.put_env(:jido_gralkor, :destinations, previous_destinations),
        else: Application.delete_env(:jido_gralkor, :destinations)
    end)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "memory"]
    ])

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        destination: "memory",
        ontology: LensOntology,
        ingestion: Gralkor.Lens.Ingestion.Store
      ]
    ])
  end

  defp runtime_configuration do
    %{
      destinations: [%{name: "memory"}],
      lenses: [
        %{
          name: "observations",
          destination: "memory",
          ontology: LensOntology,
          ingestion: Gralkor.Lens.Ingestion.Store
        },
        %{
          name: "notes",
          destination: "memory",
          ingestion: Gralkor.Lens.Ingestion.Store
        }
      ],
      reflections: []
    }
  end
end
