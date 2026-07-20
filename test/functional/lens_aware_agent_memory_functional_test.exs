defmodule JidoGralkor.LensAwareAgentMemoryFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Client.InMemory
  alias Gralkor.Ingest
  alias JidoGralkor.Actions.MemoryAdd
  alias JidoGralkor.Actions.MemorySearch
  alias JidoGralkor.Plugin

  defmodule MemoryOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Memory do
      field(:content, :string, required: true)
    end
  end

  defmodule StoreIngestion do
    @behaviour Gralkor.Lens.Ingestion

    @impl true
    def ingest(request, store) do
      Gralkor.Lens.Store.add(store, request.content, request.source_description)
    end
  end

  setup do
    previous_client = Application.get_env(:jido_gralkor, :client)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)
    previous_ontology = Application.get_env(:jido_gralkor, :ontology)

    start_supervised!(Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :client, InMemory)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
    Application.put_env(:jido_gralkor, :ontology, MemoryOntology)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        ontology: MemoryOntology,
        scope: :operator,
        ingestion: StoreIngestion
      ],
      [
        name: "decisions",
        ontology: MemoryOntology,
        scope: :operator,
        ingestion: StoreIngestion
      ],
      [
        name: "generalisations",
        ontology: MemoryOntology,
        scope: :global,
        ingestion: StoreIngestion
      ]
    ])

    InMemory.reset()
    InMemory.set_capture(:ok)

    on_exit(fn ->
      restore_env(:client, previous_client)
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
      restore_env(:ontology, previous_ontology)
    end)

    :ok
  end

  describe "when a mounted memory plugin has a configured default ingestion Lens and optional additional search targets" do
    test "then automatic capture and memory addition use the registered default ingestion Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: []
               )

      agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(agent)

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{content: "remembered observation", source_description: "agent"},
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert eventually(fn ->
               Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "observations"}) != []
             end)

      completion = completion_agent(agent, "default-request", tool_context)

      assert {:ok, :continue} =
               Plugin.handle_signal(
                 completion_signal("default-request", "remembered"),
                 %{agent: completion}
               )

      assert [[_, _, _, _, _, "observations"]] = InMemory.captures()
    end

    test "and memory search always includes the requesting operator's reserved `default` target" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "default",
                 content: "baseline memory",
                 source_description: "legacy"
               })

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations"]
               )

      agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(agent)

      assert {:ok, %{result: result}} =
               MemorySearch.run(
                 %{query: "memory"},
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert result == "baseline memory"
    end

    test "and memory search also includes the configured additional search targets" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "observations",
                 content: "observation memory",
                 source_description: "functional"
               })

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations"]
               )

      agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(agent)

      assert {:ok, %{result: "observation memory"}} =
               MemorySearch.run(
                 %{query: "memory"},
                 Map.put(tool_context, :agent_id, agent.id)
               )
    end

    test "and the plugin does not redefine a selected Lens's ontology, scope, or ingestion process" do
      assert {:ok, %{lens: lens}} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      assert %Gralkor.Lens{
               name: "observations",
               ontology: MemoryOntology,
               scope: :operator,
               ingestion: StoreIngestion
             } = lens
    end
  end

  describe "where a mounted memory plugin has no additional search targets" do
    test "then memory search uses only the requesting operator's reserved `default` target" do
      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "default",
                 content: "baseline memory",
                 source_description: "legacy"
               })

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      query_signal = %Jido.Signal{
        id: "query-signal",
        source: "/functional",
        type: "ai.react.query",
        data: %{query: "baseline"}
      }

      agent = %{
        id: "operator-one",
        state: %{__memory__: plugin_state, __thread__: %{id: "session-one"}}
      }

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(query_signal, %{agent: agent})

      assert {:ok, %{result: "baseline memory"}} =
               MemorySearch.run(
                 %{query: "baseline"},
                 Map.put(tool_context, :agent_id, agent.id)
               )
    end
  end

  describe "where an agent turn selects another registered Lens" do
    test "then memory addition uses the turn-selected Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      agent = agent(plugin_state)

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               query(agent, "decisions")

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{content: "Friday decision", source_description: "agent"},
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert eventually(fn ->
               Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "decisions"}) != []
             end)
    end

    test "and that Lens is retained for the request" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      assert {:ok, {:continue, %{data: %{tool_context: %{lens: "decisions"}}}}} =
               query(agent(plugin_state), "decisions")
    end

    test "when the matching request completes without repeating its Lens, then automatic capture uses the retained request Lens rather than the plugin default" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_targets: ["observations"]
               )

      request_id = "decision-request"

      query_signal = %Jido.Signal{
        id: "query-signal",
        source: "/functional",
        type: "ai.react.query",
        data: %{
          request_id: request_id,
          query: "Record a decision",
          tool_context: %{lens: "decisions"}
        }
      }

      query_agent = %{
        id: "operator-one",
        state: %{__memory__: plugin_state, __thread__: %{id: "session-one"}}
      }

      assert {:ok, {:continue, %{data: %{tool_context: retained_context}}}} =
               Plugin.handle_signal(query_signal, %{agent: query_agent})

      completion_agent = %{
        query_agent
        | state:
            Map.merge(query_agent.state, %{
              __strategy__: %{
                run_tool_context: retained_context,
                request_traces: %{
                  request_id => %{events: [%{kind: :llm_completed, data: %{}}]}
                }
              },
              requests: %{
                request_id => %{query: "Record a decision", status: :pending, result: nil}
              },
              user_name: "Eli"
            })
      }

      completion_signal = %Jido.Signal{
        id: "completion-signal",
        source: "/functional",
        type: "ai.request.completed",
        data: %{request_id: request_id, result: "We chose Friday."}
      }

      assert {:ok, :continue} =
               Plugin.handle_signal(completion_signal, %{agent: completion_agent})

      assert [["session-one", "operator-one", "Susu", "Eli", _messages, "decisions"]] =
               InMemory.captures()
    end

    test "when the matching request fails without repeating its Lens, then automatic capture uses the retained request Lens rather than the plugin default" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      request_id = "failed-decision-request"
      query_agent = agent(plugin_state)

      assert {:ok, {:continue, %{data: %{tool_context: retained_context}}}} =
               query(query_agent, "decisions", request_id)

      failed_agent = completion_agent(query_agent, request_id, retained_context)

      failure_signal = %Jido.Signal{
        id: "failure-signal",
        source: "/functional",
        type: "ai.request.failed",
        data: %{request_id: request_id, error: :rejected}
      }

      assert {:ok, :continue} = Plugin.handle_signal(failure_signal, %{agent: failed_agent})
      assert [[_, _, _, _, _, "decisions"]] = InMemory.captures()
    end
  end

  describe "when turns in one session select different Lenses" do
    test "then each Lens retains only the turns selected for it" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      for {request_id, lens, result} <- [
            {"observation-request", "observations", "Observed."},
            {"decision-request", "decisions", "Decided."}
          ] do
        base_agent = agent(plugin_state)

        assert {:ok, {:continue, %{data: %{tool_context: retained_context}}}} =
                 query(base_agent, lens, request_id)

        completed_agent = completion_agent(base_agent, request_id, retained_context)

        assert {:ok, :continue} =
                 Plugin.handle_signal(
                   completion_signal(request_id, result),
                   %{agent: completed_agent}
                 )
      end

      assert [
               [_, _, _, _, observation_messages, "observations"],
               [_, _, _, _, decision_messages, "decisions"]
             ] = InMemory.captures()

      assert Enum.any?(observation_messages, &(&1.content == "Observed."))
      assert Enum.any?(decision_messages, &(&1.content == "Decided."))
    end

    test "and no flushed episode combines turns governed by different ontologies or ingestion processes" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      for {request_id, lens} <- [
            {"observation-request", "observations"},
            {"decision-request", "decisions"}
          ] do
        base_agent = agent(plugin_state)

        assert {:ok, {:continue, %{data: %{tool_context: retained_context}}}} =
                 query(base_agent, lens, request_id)

        assert {:ok, :continue} =
                 Plugin.handle_signal(
                   completion_signal(request_id, "#{lens} result"),
                   %{agent: completion_agent(base_agent, request_id, retained_context)}
                 )
      end

      assert Enum.map(InMemory.captures(), &List.last/1) == ["observations", "decisions"]
    end

    test "and captured turns retain their original order" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 default_lens: "observations"
               )

      for request_id <- ["first-request", "second-request"] do
        base_agent = agent(plugin_state)

        assert {:ok, {:continue, %{data: %{tool_context: retained_context}}}} =
                 query(base_agent, "observations", request_id)

        assert {:ok, :continue} =
                 Plugin.handle_signal(
                   completion_signal(request_id, request_id),
                   %{agent: completion_agent(base_agent, request_id, retained_context)}
                 )
      end

      assert [first_capture, second_capture] = InMemory.captures()
      assert Enum.any?(Enum.at(first_capture, 4), &(&1.content == "first-request"))
      assert Enum.any?(Enum.at(second_capture, 4), &(&1.content == "second-request"))
    end
  end

  describe "if a mounted plugin receives invalid Lens configuration" do
    test "then mounting fails before the plugin handles an agent signal" do
      assert_raise ArgumentError, fn ->
        Plugin.mount(%{}, agent_name: "Susu", default_lens: "missing")
      end
    end

    test "where the default Lens is unknown, then the error identifies the unknown default Lens" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Plugin.mount(%{}, agent_name: "Susu", default_lens: "missing")
      end
    end

    test "where a search target is invalid, then the error identifies the invalid target" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          default_lens: "observations",
          search_targets: ["missing"]
        )
      end
    end

    test "where the generalising Lens is unknown, then the error identifies the unknown generalising Lens" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          default_lens: "observations",
          generalise_lens: "missing"
        )
      end
    end

    test "where the generalising Lens duplicates the default Lens, then the error identifies that the two selections must differ" do
      assert_raise ArgumentError, ~r/must differ/, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          default_lens: "observations",
          generalise_lens: "observations"
        )
      end
    end

    test "where Lens options are supplied without a default Lens, then the error identifies that a default Lens is required" do
      assert_raise ArgumentError, ~r/default_lens is required/, fn ->
        Plugin.mount(%{}, agent_name: "Susu", search_targets: ["observations"])
      end
    end
  end

  defp agent(plugin_state) do
    %{
      id: "operator-one",
      state: %{
        __memory__: plugin_state,
        __thread__: %{id: "session-one"},
        user_name: "Eli"
      }
    }
  end

  defp query(agent, lens \\ nil, request_id \\ "query-request") do
    tool_context = if lens, do: %{lens: lens}, else: %{}

    signal = %Jido.Signal{
      id: "query-signal-#{request_id}",
      source: "/functional",
      type: "ai.react.query",
      data: %{
        request_id: request_id,
        query: "Remember this",
        tool_context: tool_context
      }
    }

    Plugin.handle_signal(signal, %{agent: agent})
  end

  defp completion_agent(agent, request_id, retained_context) do
    %{
      agent
      | state:
          Map.merge(agent.state, %{
            __strategy__: %{
              run_tool_context: retained_context,
              request_traces: %{
                request_id => %{events: [%{kind: :llm_completed, data: %{}}]}
              }
            },
            requests: %{
              request_id => %{query: request_id, status: :pending, result: nil}
            }
          })
    }
  end

  defp completion_signal(request_id, result) do
    %Jido.Signal{
      id: "completion-signal-#{request_id}",
      source: "/functional",
      type: "ai.request.completed",
      data: %{request_id: request_id, result: result}
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
