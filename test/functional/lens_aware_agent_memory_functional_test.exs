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
    previous_destinations = Application.get_env(:jido_gralkor, :destinations)
    previous_destination_storage = Application.get_env(:jido_gralkor, :destination_storage)
    previous_lenses = Application.get_env(:jido_gralkor, :lenses)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)

    start_supervised!(Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :client, InMemory)

    Application.put_env(:jido_gralkor, :destinations, [
      [name: "observations"],
      [name: "decisions"]
    ])

    Application.put_env(
      :jido_gralkor,
      :destination_storage,
      Gralkor.Destination.Storage.InMemory
    )

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        destination: "observations",
        ontology: MemoryOntology,
        ingestion: StoreIngestion
      ],
      [
        name: "decisions",
        destination: "decisions",
        ontology: MemoryOntology,
        ingestion: StoreIngestion
      ],
      [
        name: "shared-generalisations",
        destination: "global",
        ingestion: StoreIngestion
      ]
    ])

    InMemory.reset()
    InMemory.set_capture(:ok)

    on_exit(fn ->
      restore_env(:client, previous_client)
      restore_env(:destinations, previous_destinations)
      restore_env(:destination_storage, previous_destination_storage)
      restore_env(:lenses, previous_lenses)
      restore_env(:lens_storage, previous_storage)
    end)

    :ok
  end

  describe "when an agent with a mounted memory plugin invokes memory search" do
    test "then optional Destination and Lens selectors belong only to that search invocation" do
      for {lens, content} <- [
            {"observations", "selected observation memory"},
            {"decisions", "selected decision memory"}
          ] do
        assert :ok =
                 Client.ingest(%Ingest{
                   id: "search-selector-#{lens}",
                   operator_id: "operator-one",
                   lens: lens,
                   source_kind: :document,
                   content: content,
                   source_description: "functional"
                 })
      end

      assert {:ok, plugin_state} =
               Plugin.mount(%{}, agent_name: "Susu", ingestion_lens: "observations")

      mounted_agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(mounted_agent)
      search_context = Map.put(tool_context, :agent_id, mounted_agent.id)

      assert {:ok, %{result: result}} =
               MemorySearch.run(
                 %{
                   query: "selected",
                   destinations: ["observations", "decisions"],
                   lenses: ["decisions"]
                 },
                 search_context
               )

      assert Jason.decode!(result) == [
               %{
                 "destination" => "decisions",
                 "episode" => %{
                   "content" => "selected decision memory",
                   "lens" => "decisions"
                 }
               }
             ]

      assert search_context.lens == "observations"
    end

    test "and search selectors neither default from nor change the configured ingestion Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{}, agent_name: "Susu", ingestion_lens: "observations")

      mounted_agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(mounted_agent)
      memory_context = Map.put(tool_context, :agent_id, mounted_agent.id)

      assert {:ok, %{result: "[]"}} =
               MemorySearch.run(
                 %{query: "decision", destinations: ["decisions"], lenses: ["decisions"]},
                 memory_context
               )

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "observation retained after selected search",
                   source_kind: :document,
                   source_description: "functional"
                 },
                 memory_context
               )

      assert eventually(fn ->
               Enum.any?(destination_episodes("observations"), fn episode ->
                 episode.content == "observation retained after selected search"
               end)
             end)

      assert destination_episodes("decisions") == []
    end

    test "and a turn-selected ingestion Lens neither defaults nor restricts memory search" do
      assert :ok =
               Client.ingest(%Ingest{
                 id: "turn-lens-independent-search",
                 operator_id: "operator-one",
                 lens: "observations",
                 source_kind: :document,
                 content: "observation visible from a decision turn",
                 source_description: "functional"
               })

      assert {:ok, plugin_state} =
               Plugin.mount(%{}, agent_name: "Susu", ingestion_lens: "observations")

      mounted_agent = agent(plugin_state)

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               query(mounted_agent, "decisions")

      assert tool_context.lens == "decisions"

      assert {:ok, %{result: result}} =
               MemorySearch.run(
                 %{query: "observation", destinations: ["observations"]},
                 Map.put(tool_context, :agent_id, mounted_agent.id)
               )

      assert Jason.decode!(result) == [
               %{
                 "destination" => "observations",
                 "episode" => %{
                   "content" => "observation visible from a decision turn",
                   "lens" => "observations"
                 }
               }
             ]
    end

    test "where no conversation thread has been committed then memory search still runs for the current operator" do
      assert :ok =
               Client.ingest(%Ingest{
                 id: "first-turn-search",
                 operator_id: "operator-one",
                 lens: "observations",
                 source_kind: :document,
                 content: "first-turn searchable memory",
                 source_description: "functional"
               })

      assert {:ok, plugin_state} =
               Plugin.mount(%{}, agent_name: "Susu", ingestion_lens: "observations")

      fresh_agent = %{agent(plugin_state) | state: Map.delete(agent(plugin_state).state, :__thread__)}

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(fresh_agent)
      refute Map.has_key?(tool_context, :session_id)

      assert {:ok, %{result: result}} =
               MemorySearch.run(
                 %{query: "first-turn", destinations: ["observations"]},
                 Map.put(tool_context, :agent_id, fresh_agent.id)
               )

      assert [%{"destination" => "observations"}] = Jason.decode!(result)
    end
  end

  describe "when a mounted memory plugin has a configured ingestion Lens" do
    test "then automatic capture and memory addition use the registered ingestion Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      agent = agent(plugin_state)
      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} = query(agent)

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "remembered observation",
                   source_kind: :conversation,
                   source_description: "agent"
                 },
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert eventually(fn ->
               destination_episodes("observations") != []
             end)

      completion = completion_agent(agent, "default-request", tool_context)

      assert {:ok, :continue} =
               Plugin.handle_signal(
                 completion_signal("default-request", "remembered"),
                 %{agent: completion}
               )

      assert [[_, _, _, _, _, "observations", [], _reflection_context]] = InMemory.captures()
    end

    test "and the plugin does not redefine the selected Lens's Destination or ingestion process" do
      assert {:ok, %{lens: lens}} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      assert %Gralkor.Lens{
               name: "observations",
               destination: %Gralkor.Destination{name: "observations"},
               ontology: MemoryOntology,
               ingestion: StoreIngestion
             } = lens
    end
  end

  describe "where an agent turn selects another registered Lens" do
    test "then memory addition uses the turn-selected Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      agent = agent(plugin_state)

      assert {:ok, {:continue, %{data: %{tool_context: tool_context}}}} =
               query(agent, "decisions")

      assert {:ok, %{result: "Ingesting."}} =
               MemoryAdd.run(
                 %{
                   content: "Friday decision",
                   source_kind: :conversation,
                   source_description: "agent"
                 },
                 Map.put(tool_context, :agent_id, agent.id)
               )

      assert eventually(fn ->
               destination_episodes("decisions") != []
             end)
    end

    test "and that Lens is retained for the request" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      assert {:ok,
              {:continue,
               %{
                 data: %{
                   tool_context: %{lens: "decisions"},
                   extra_refs: %{jido_gralkor_lens: "decisions"}
                 }
               }}} =
               query(agent(plugin_state), "decisions")
    end

    test "and completion without a repeated Lens captures through the retained request Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations",
                 search_destinations: ["observations"]
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

      assert {:ok, {:continue, %{data: %{extra_refs: retained_refs}}}} =
               Plugin.handle_signal(query_signal, %{agent: query_agent})

      completion_agent = %{
        query_agent
        | state:
            Map.merge(query_agent.state, %{
              __strategy__: %{
                request_traces: %{
                  request_id => %{events: [%{kind: :llm_completed, data: %{}}]}
                }
              },
              __thread__: thread_with_request_lens(request_id, retained_refs),
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

      assert [["session-one", "operator-one", "Susu", "Eli", _messages, "decisions", [], _]] =
               InMemory.captures()
    end

    test "and failure without a repeated Lens captures through the retained request Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      request_id = "failed-decision-request"
      query_agent = agent(plugin_state)

      assert {:ok, {:continue, %{data: %{extra_refs: retained_refs}}}} =
               query(query_agent, "decisions", request_id)

      failed_agent = completion_agent(query_agent, request_id, retained_refs)

      failure_signal = %Jido.Signal{
        id: "failure-signal",
        source: "/functional",
        type: "ai.request.failed",
        data: %{request_id: request_id, error: :rejected}
      }

      assert {:ok, :continue} = Plugin.handle_signal(failure_signal, %{agent: failed_agent})
      assert [[_, _, _, _, _, "decisions", [], _]] = InMemory.captures()
    end
  end

  describe "if an agent turn selects an unknown or non-binary Lens" do
    test "then handling the turn fails before memory addition or capture and identifies the invalid Lens" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{}, agent_name: "Susu", ingestion_lens: "observations")

      for invalid <- ["missing", 42] do
        signal = %Jido.Signal{
          id: "invalid-lens",
          source: "/functional",
          type: "ai.react.query",
          data: %{query: "Remember this", tool_context: %{lens: invalid}}
        }

        assert_raise ArgumentError, ~r/unknown Lens|invalid Lens/, fn ->
          Plugin.handle_signal(signal, %{agent: agent(plugin_state)})
        end
      end

      assert InMemory.adds() == []
      assert InMemory.captures() == []
    end
  end

  describe "when a mounted memory plugin captures through a Lens for an agent request" do
    test "then the host agent's configured tools reach every scheduled Reflection" do
      context = reflection_capture_context([:host_tool], %{}, %{})
      assert context.tools == [:host_tool]
    end

    test "and the retained request tool context reaches every scheduled Reflection" do
      context = reflection_capture_context([], %{}, %{tenant: "retained"})
      assert context.tool_context.tenant == "retained"
    end

    test "and the current operator, agent name, Lens, and session id override conflicting configured or retained context" do
      conflicts = %{
        operator_id: "wrong",
        agent_name: "Wrong",
        lens: "observations",
        session_id: "wrong",
        precedence: "retained"
      }

      context =
        reflection_capture_context([], Map.put(conflicts, :precedence, "configured"), conflicts)

      assert context.tool_context.operator_id == "operator-one"
      assert context.tool_context.agent_name == "Susu"
      assert context.tool_context.lens == "decisions"
      assert context.tool_context.session_id == "session-one"
      assert context.tool_context.precedence == "retained"
    end

    test "and the current operator is supplied as the host agent identifier expected by forwarded tools" do
      context =
        reflection_capture_context(
          [],
          %{agent_id: "configured-agent"},
          %{agent_id: "retained-agent"}
        )

      assert context.tool_context.agent_id == "operator-one"
    end
  end

  describe "when turns in one session select different Lenses" do
    test "then each Lens retains only the turns selected for it" do
      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      for {request_id, lens, result} <- [
            {"observation-request", "observations", "Observed."},
            {"decision-request", "decisions", "Decided."}
          ] do
        base_agent = agent(plugin_state)

        assert {:ok, {:continue, %{data: %{extra_refs: retained_refs}}}} =
                 query(base_agent, lens, request_id)

        completed_agent = completion_agent(base_agent, request_id, retained_refs)

        assert {:ok, :continue} =
                 Plugin.handle_signal(
                   completion_signal(request_id, result),
                   %{agent: completed_agent}
                 )
      end

      assert [
               [_, _, _, _, observation_messages, "observations", [], _],
               [_, _, _, _, decision_messages, "decisions", [], _]
             ] = InMemory.captures()

      assert Enum.any?(observation_messages, &(&1.content == "Observed."))
      assert Enum.any?(decision_messages, &(&1.content == "Decided."))
    end

    test "and no flushed episode combines turns governed by different ontologies or ingestion processes" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
      start_lens_capture_buffer()

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      for {request_id, lens} <- [
            {"observation-request", "observations"},
            {"decision-request", "decisions"}
          ] do
        base_agent = agent(plugin_state)

        assert {:ok, {:continue, %{data: %{extra_refs: retained_refs}}}} =
                 query(base_agent, lens, request_id)

        assert {:ok, :continue} =
                 Plugin.handle_signal(
                   completion_signal(request_id, "#{lens} result"),
                   %{agent: completion_agent(base_agent, request_id, retained_refs)}
                 )
      end

      assert :ok = Gralkor.Client.Native.flush_and_await("session-one", 1_000)

      assert [%{content: observation_episode}] =
               destination_episodes("observations")

      assert [%{content: decision_episode}] =
               destination_episodes("decisions")

      assert observation_episode =~ "observations result"
      refute observation_episode =~ "decisions result"
      assert decision_episode =~ "decisions result"
      refute decision_episode =~ "observations result"
    end

    test "and captured turns retain their original order" do
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
      start_lens_capture_buffer()

      assert {:ok, plugin_state} =
               Plugin.mount(%{},
                 agent_name: "Susu",
                 ingestion_lens: "observations"
               )

      for request_id <- ["first-request", "second-request"] do
        base_agent = agent(plugin_state)

        assert {:ok, {:continue, %{data: %{extra_refs: retained_refs}}}} =
                 query(base_agent, "observations", request_id)

        assert {:ok, :continue} =
                 Plugin.handle_signal(
                   completion_signal(request_id, request_id),
                   %{agent: completion_agent(base_agent, request_id, retained_refs)}
                 )
      end

      assert :ok = Gralkor.Client.Native.flush_and_await("session-one", 1_000)

      assert [%{content: episode}] =
               destination_episodes("observations")

      {first_position, _first_length} = :binary.match(episode, "first-request")
      {second_position, _second_length} = :binary.match(episode, "second-request")
      assert first_position < second_position
    end
  end

  describe "if a mounted plugin receives invalid ingestion Lens configuration" do
    test "then mounting fails before the plugin handles an agent signal" do
      assert_raise ArgumentError, fn ->
        Plugin.mount(%{}, agent_name: "Susu", ingestion_lens: "missing")
      end
    end

    test "and an unknown ingestion Lens is identified" do
      assert_raise ArgumentError, ~r/unknown Lens "missing"/, fn ->
        Plugin.mount(%{}, agent_name: "Susu", ingestion_lens: "missing")
      end
    end

    test "and the removed `:default_lens` option identifies `:ingestion_lens` as its replacement" do
      assert_raise ArgumentError, ~r/default_lens.*ingestion_lens/, fn ->
        Plugin.mount(%{}, agent_name: "Susu", default_lens: "observations")
      end
    end
  end

  describe "if a mounted plugin receives the removed `:search_destinations` option" do
    test "then mounting fails before the plugin handles an agent signal and the error identifies MemorySearch's per-search `destinations` selector as its replacement" do
      assert_raise ArgumentError, ~r/search_destinations.*MemorySearch.*destinations/s, fn ->
        Plugin.mount(%{},
          agent_name: "Susu",
          ingestion_lens: "observations",
          search_destinations: ["observations"]
        )
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

  defp completion_agent(agent, request_id, retained_refs) do
    %{
      agent
      | state:
          Map.merge(agent.state, %{
            __strategy__: %{
              request_traces: %{
                request_id => %{events: [%{kind: :llm_completed, data: %{}}]}
              }
            },
            __thread__: thread_with_request_lens(request_id, retained_refs),
            requests: %{
              request_id => %{query: request_id, status: :pending, result: nil}
            }
          })
    }
  end

  defp thread_with_request_lens(request_id, retained_refs) do
    %{
      id: "session-one",
      entries: [
        %{
          kind: :ai_message,
          payload: %{role: :user},
          refs: Map.put(retained_refs, :request_id, request_id)
        }
      ]
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

  defp reflection_capture_context(tools, configured_tool_context, retained_tool_context) do
    assert {:ok, plugin_state} =
             Plugin.mount(%{}, agent_name: "Susu", ingestion_lens: "observations")

    request_id = "reflection-context"
    query_agent = agent(plugin_state)

    signal = %Jido.Signal{
      id: "query-reflection-context",
      source: "/functional",
      type: "ai.react.query",
      data: %{
        request_id: request_id,
        query: "Remember this",
        tool_context: Map.put(retained_tool_context, :lens, "decisions")
      }
    }

    assert {:ok, {:continue, %{data: %{extra_refs: retained_refs}}}} =
             Plugin.handle_signal(signal, %{agent: query_agent})

    completed_agent = completion_agent(query_agent, request_id, retained_refs)

    completed_agent =
      put_in(
        completed_agent,
        [:state, :__strategy__, :config],
        %{tools: tools, tool_context: configured_tool_context}
      )

    assert {:ok, :continue} =
             Plugin.handle_signal(completion_signal(request_id, "remembered"), %{
               agent: completed_agent
             })

    assert [[_, _, _, _, _, "decisions", [], context]] = InMemory.captures()
    context
  end

  defp start_lens_capture_buffer do
    start_supervised!(
      {Gralkor.CaptureBuffer,
       flush_callback: fn _, _, _, _, _ -> :ok end,
       lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
       retries: []}
    )
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

  defp destination_episodes(name) do
    name
    |> Gralkor.Destination.Registry.fetch!()
    |> Gralkor.Destination.graph_id("operator-one")
    |> Gralkor.Lens.Storage.InMemory.episodes()
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
