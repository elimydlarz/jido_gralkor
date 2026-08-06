defmodule JidoGralkor.PluginTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client.InMemory
  alias Gralkor.Message
  alias Jido.Signal
  alias JidoGralkor.Plugin

  defmodule LensOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open
  end

  setup_all do
    {:ok, _applications} = Application.ensure_all_started(:jido_signal)
    :ok
  end

  setup do
    InMemory.reset()
    :ok
  end

  defp agent(id, opts) do
    thread_id = Keyword.get(opts, :thread_id, "thr-default")
    request_traces = Keyword.get(opts, :request_traces, %{})
    requests = Keyword.get(opts, :requests, %{})
    agent_name = Keyword.get(opts, :agent_name, "TestAgent")
    user_name = Keyword.get(opts, :user_name, "Eli")

    state =
      %{
        __strategy__: %{request_traces: request_traces},
        requests: requests,
        __memory__: %{agent_name: agent_name},
        user_name: user_name
      }
      |> maybe_put(:__thread__, if(thread_id, do: %{id: thread_id}, else: nil))

    %{id: id, state: state}
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp context(agent), do: %{agent: agent}

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
               Plugin.mount(%{id: "user-1", state: %{}}, agent_name: "Susu")
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

  describe "when mount selects a default Lens, Lenses to search, and an optional generalising Lens" do
    test "then those selections are resolved against the application Lens registry and stored on the plugin state" do
      configure_lenses()

      assert {:ok,
              %{
                agent_name: "Susu",
                default_lens: "observations",
                search_lenses: ["observations", "global"],
                generalise_lens: "generalisations",
                lens: %Gralkor.Lens{
                  name: "observations",
                  ontology: LensOntology,
                  scope: :operator,
                  ingestion: Gralkor.Lens.Ingestion.Store
                }
              }} =
               Plugin.mount(%{id: "operator-one", state: %{}},
                 agent_name: "Susu",
                 default_lens: "observations",
                 search_lenses: ["observations", "global"],
                 generalise_lens: "generalisations"
               )
    end

    test "and the resolved Lens keeps the ontology, scope, and ingestion the registry declared for it, redefining none of them" do
      state = lens_plugin_state()

      assert state.lens == %Gralkor.Lens{
               name: "observations",
               ontology: LensOntology,
               scope: :operator,
               ingestion: Gralkor.Lens.Ingestion.Store
             }
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
  end

  describe "when an agent turn begins > where the plugin was mounted with Lens selections > while a thread has committed to agent state" do
    test "then the Lens selections and committed session id are planted on the tool context beside the agent name" do
      plugin_state = lens_plugin_state()
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      lens_agent =
        agent("operator-one", thread_id: "thread-one")
        |> put_in([:state, :__memory__], plugin_state)

      assert {:ok, {:continue, %Signal{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, context(lens_agent))

      assert tool_context == %{
               agent_name: "Susu",
               lens: "observations",
               search_lenses: ["observations", "global"],
               session_id: "thread-one"
             }
    end
  end

  describe "when an agent turn begins > where the plugin was mounted with Lens selections > while no thread has committed to agent state" do
    test "then the Lens selections are planted on the tool context beside the agent name without a session id" do
      plugin_state = lens_plugin_state()
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      lens_agent =
        agent("operator-one", thread_id: nil)
        |> put_in([:state, :__memory__], plugin_state)

      assert {:ok, {:continue, %Signal{data: %{tool_context: tool_context}}}} =
               Plugin.handle_signal(signal, context(lens_agent))

      assert tool_context == %{
               agent_name: "Susu",
               lens: "observations",
               search_lenses: ["observations", "global"]
             }
    end
  end

  describe "when an agent turn begins > while no thread has committed to agent state" do
    test "then only the mounted agent name is planted on the tool context, with no session id" do
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      assert {:ok, {:continue, %Signal{data: data}}} =
               Plugin.handle_signal(signal, context(agent("user-abc", thread_id: nil)))

      assert data.tool_context.agent_name == "TestAgent"
      refute Map.has_key?(data.tool_context, :session_id)
    end

    test "and no recall is issued on the plugin's own initiative" do
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      Plugin.handle_signal(signal, context(agent("user-abc", thread_id: nil)))

      assert InMemory.recalls() == []
    end
  end

  describe "when an agent turn completes > while a thread has committed to agent state" do
    test "then the turn is sent for capture as canonical messages under that thread's session id and the operator's sanitised group id" do
      [session_id, group_id, _agent_name, _user_name, messages] = completed_capture()
      assert session_id == "thr-42"
      assert group_id == "user_42"
      assert Enum.all?(messages, &match?(%Message{}, &1))
    end

    test "and the user name held in agent state is forwarded with the capture" do
      [_session_id, _group_id, _agent_name, user_name, _messages] = completed_capture()
      assert user_name == "Eli"
    end

    test "and the user's query opens the captured messages" do
      [_session_id, _group_id, _agent_name, _user_name, messages] = completed_capture()
      assert hd(messages) == %Message{role: "user", content: "what did I say?"}
    end

    test "and the completed answer closes them" do
      [_session_id, _group_id, _agent_name, _user_name, messages] = completed_capture()
      assert List.last(messages) == %Message{role: "assistant", content: "you said hi"}
    end
  end

  describe "when an agent turn completes > while a thread has committed to agent state > if agent state holds no user name" do
    test "then the callback raises ArgumentError naming the missing user name" do
      InMemory.set_capture(:ok)
      request_id = "req-no-user"

      ag = %{
        id: "user-42",
        state: %{
          __strategy__: %{
            request_traces: %{
              request_id => %{
                events: [%{kind: :llm_completed, data: %{}}],
                truncated?: false
              }
            }
          },
          requests: %{request_id => %{query: "hi", status: :pending, result: nil}},
          __memory__: %{agent_name: "TestAgent"},
          __thread__: %{id: "thr-42"}
        }
      }

      signal =
        Signal.new!(
          "ai.request.completed",
          %{request_id: request_id, result: "yo"},
          source: "/test"
        )

      assert_raise ArgumentError, ~r/user_name/, fn ->
        Plugin.handle_signal(signal, context(ag))
      end
    end
  end

  describe "when an agent turn completes > while a thread has committed to agent state > if agent state holds a blank user name" do
    test "then the callback raises ArgumentError naming the missing user name" do
      InMemory.set_capture(:ok)
      request_id = "req-blank-user"

      ag =
        agent("user-42",
          user_name: "   ",
          thread_id: "thr-42",
          request_traces: %{
            request_id => %{
              events: [%{kind: :llm_completed, data: %{}}],
              truncated?: false
            }
          },
          requests: %{request_id => %{query: "hi", status: :pending, result: nil}}
        )

      signal =
        Signal.new!(
          "ai.request.completed",
          %{request_id: request_id, result: "yo"},
          source: "/test"
        )

      assert_raise ArgumentError, ~r/user_name/, fn ->
        Plugin.handle_signal(signal, context(ag))
      end
    end
  end

  describe "when an agent turn completes > while no thread has committed to agent state" do
    test "then capture is skipped" do
      {_log, captures} = completed_without_thread()
      assert captures == []
    end

    test "and a warning naming the operator is logged" do
      {log, _captures} = completed_without_thread()
      assert log =~ "user-01"
    end
  end

  describe "when an agent turn completes > while a thread has committed to agent state > while the completed turn's request trace holds no events" do
    test "then no capture is sent at all" do
      InMemory.set_capture(:ok)
      request_id = "req-empty"

      ag =
        agent("user-01",
          thread_id: "thr-empty",
          request_traces: %{request_id => %{events: [], truncated?: false}},
          requests: %{request_id => %{query: "q", status: :pending, result: nil}}
        )

      signal =
        Signal.new!("ai.request.completed", %{request_id: request_id, result: "a"},
          source: "/test"
        )

      Plugin.handle_signal(signal, context(ag))

      assert InMemory.captures() == []
    end
  end

  describe "when an agent turn completes > while a thread has committed to agent state > where the plugin was mounted with Lens selections" do
    test "then the capture also carries the selected Lens and the optional generalising Lens" do
      InMemory.set_capture(:ok)
      plugin_state = lens_plugin_state()
      request_id = "request-lens-capture"

      lens_agent =
        agent("operator-one",
          agent_name: "Susu",
          thread_id: "thread-one",
          request_traces: %{
            request_id => %{events: [%{kind: :llm_completed, data: %{}}], truncated?: false}
          },
          requests: %{request_id => %{query: "Remember this", status: :pending, result: nil}}
        )
        |> put_in([:state, :__memory__], plugin_state)

      signal =
        Signal.new!(
          "ai.request.completed",
          %{request_id: request_id, result: "Remembered."},
          source: "/test"
        )

      assert {:ok, :continue} = Plugin.handle_signal(signal, context(lens_agent))

      assert [
               [
                 "thread-one",
                 "operator-one",
                 "Susu",
                 "Eli",
                 _messages,
                 "observations",
                 ["generalisations"]
               ]
             ] = InMemory.captures()
    end
  end

  describe "when an agent turn fails > while a thread has committed to agent state" do
    test "then the turn is captured with the failure surfaced as a terminal `request failed: …` behaviour message" do
      [_session_id, _group_id, _agent_name, _user_name, messages] = failed_capture()

      assert List.last(messages) == %Message{
               role: "behaviour",
               content: "request failed: :boom"
             }
    end

    test "and no assistant message is captured for the failed turn" do
      [_session_id, _group_id, _agent_name, _user_name, messages] = failed_capture()
      refute Enum.any?(messages, &(&1.role == "assistant"))
    end

    test "and the user's original query is captured ahead of the failure message" do
      [_session_id, _group_id, _agent_name, _user_name, messages] = failed_capture()
      user_msg = Enum.find(messages, &(&1.role == "user"))
      assert user_msg.content == "original question"
      assert Enum.find_index(messages, &(&1.role == "user")) < length(messages) - 1
    end
  end

  describe "when an agent turn fails > while no thread has committed to agent state" do
    test "then capture is skipped" do
      {_log, captures} = failed_without_thread()
      assert captures == []
    end

    test "and a warning naming the operator is logged" do
      {log, _captures} = failed_without_thread()
      assert log =~ "user-01"
    end
  end

  describe "when a signal of any other type arrives" do
    test "then the plugin lets the signal continue untouched" do
      ag = agent("user-other", thread_id: "thr-other")
      signal = Signal.new!("ai.llm.delta", %{token: "x"}, source: "/test")

      assert {:ok, :continue} = Plugin.handle_signal(signal, context(ag))
    end

    test "and nothing is captured" do
      ag = agent("user-other", thread_id: "thr-other")
      signal = Signal.new!("ai.llm.delta", %{token: "x"}, source: "/test")
      Plugin.handle_signal(signal, context(ag))
      assert InMemory.captures() == []
    end

    test "and nothing is recalled" do
      ag = agent("user-other", thread_id: "thr-other")
      signal = Signal.new!("ai.llm.delta", %{token: "x"}, source: "/test")
      Plugin.handle_signal(signal, context(ag))
      assert InMemory.recalls() == []
    end
  end

  describe "when an agent turn completes > while a thread has committed to agent state > if the capture call fails" do
    test "then the callback raises, reporting the capture failure" do
      InMemory.set_capture({:error, :gralkor_unreachable})
      request_id = "req-err"

      ag =
        agent("user-01",
          thread_id: "thr-err",
          request_traces: %{
            request_id => %{events: [%{kind: :llm_completed, data: %{}}], truncated?: false}
          },
          requests: %{request_id => %{query: "q", status: :pending, result: nil}}
        )

      signal =
        Signal.new!("ai.request.completed", %{request_id: request_id, result: "a"},
          source: "/test"
        )

      assert_raise RuntimeError, ~r/Gralkor capture failed.*gralkor_unreachable/, fn ->
        Plugin.handle_signal(signal, context(ag))
      end
    end
  end

  defp completed_without_thread do
    InMemory.set_capture(:ok)
    request_id = "req-first-complete"

    ag =
      agent("user-01",
        thread_id: nil,
        request_traces: %{
          request_id => %{events: [%{kind: :llm_completed, data: %{}}], truncated?: false}
        },
        requests: %{request_id => %{query: "q", status: :pending, result: nil}}
      )

    signal =
      Signal.new!("ai.request.completed", %{request_id: request_id, result: "done"},
        source: "/test"
      )

    log =
      capture_log(fn -> assert {:ok, :continue} = Plugin.handle_signal(signal, context(ag)) end)

    {log, InMemory.captures()}
  end

  defp failed_without_thread do
    InMemory.set_capture(:ok)
    request_id = "req-first-fail"

    ag =
      agent("user-01",
        thread_id: nil,
        request_traces: %{
          request_id => %{events: [%{kind: :llm_completed, data: %{}}], truncated?: false}
        },
        requests: %{request_id => %{query: "q", status: :pending, result: nil}}
      )

    signal =
      Signal.new!("ai.request.failed", %{request_id: request_id, error: :boom}, source: "/test")

    log =
      capture_log(fn -> assert {:ok, :continue} = Plugin.handle_signal(signal, context(ag)) end)

    {log, InMemory.captures()}
  end

  defp completed_capture do
    InMemory.set_capture(:ok)
    request_id = "req-xyz"

    ag =
      agent("user-42",
        thread_id: "thr-42",
        request_traces: %{
          request_id => %{
            events: [
              %{kind: :llm_completed, data: %{text: "thinking"}},
              %{kind: :tool_completed, data: %{tool_name: "memory_search", result: "..."}}
            ],
            truncated?: false
          }
        },
        requests: %{
          request_id => %{query: "what did I say?", status: :pending, result: nil}
        }
      )

    signal =
      Signal.new!("ai.request.completed", %{request_id: request_id, result: "you said hi"},
        source: "/test"
      )

    assert {:ok, :continue} = Plugin.handle_signal(signal, context(ag))
    assert [capture] = InMemory.captures()
    capture
  end

  defp failed_capture do
    InMemory.set_capture(:ok)
    request_id = "req-fail"

    ag =
      agent("user-01",
        thread_id: "thr-fail",
        request_traces: %{
          request_id => %{events: [%{kind: :llm_completed, data: %{}}], truncated?: false}
        },
        requests: %{
          request_id => %{query: "original question", status: :pending, result: nil}
        }
      )

    signal =
      Signal.new!("ai.request.failed", %{request_id: request_id, error: :boom}, source: "/test")

    Plugin.handle_signal(signal, context(ag))
    assert [capture] = InMemory.captures()
    capture
  end

  defp lens_plugin_state do
    configure_lenses()

    {:ok, plugin_state} =
      Plugin.mount(%{id: "operator-one", state: %{}},
        agent_name: "Susu",
        default_lens: "observations",
        search_lenses: ["observations", "global"],
        generalise_lens: "generalisations"
      )

    plugin_state
  end

  defp configure_lenses do
    previous = Application.get_env(:jido_gralkor, :lenses)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:jido_gralkor, :lenses, previous),
        else: Application.delete_env(:jido_gralkor, :lenses)
    end)

    Application.put_env(:jido_gralkor, :lenses, [
      [
        name: "observations",
        ontology: LensOntology,
        scope: :operator,
        ingestion: Gralkor.Lens.Ingestion.Store
      ],
      [
        name: "generalisations",
        ontology: LensOntology,
        scope: :global,
        ingestion: Gralkor.Lens.Ingestion.Generalise
      ]
    ])
  end
end
