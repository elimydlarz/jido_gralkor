defmodule JidoGralkor.PluginTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.Client.InMemory
  alias Gralkor.Message
  alias Jido.Signal
  alias JidoGralkor.Plugin

  setup do
    InMemory.reset()
    :ok
  end

  defp agent(id, opts) do
    thread_id = Keyword.get(opts, :thread_id, "thr-default")
    request_traces = Keyword.get(opts, :request_traces, %{})
    requests = Keyword.get(opts, :requests, %{})

    state =
      %{__strategy__: %{request_traces: request_traces}, requests: requests}
      |> maybe_put(:__thread__, if(thread_id, do: %{id: thread_id}, else: nil))

    %{id: id, state: state}
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp context(agent), do: %{agent: agent}

  test "the session_id is the Jido thread id — the plugin does not mint its own" do
    InMemory.set_recall({:ok, nil})
    signal = Signal.new!("ai.react.query", %{query: "q"}, source: "/test")

    assert {:ok, {:continue, %Signal{data: data}}} =
             Plugin.handle_signal(signal, context(agent("user-1", thread_id: "thr-exact")))

    assert data.tool_context.session_id == "thr-exact"
    assert [[_, "thr-exact", _]] = InMemory.recalls()
  end

  test "mount/2 returns {:ok, nil} — the plugin holds no state of its own" do
    assert {:ok, nil} = Plugin.mount(%{id: "user-1", state: %{}}, %{})
  end

  describe "when an agent turn begins" do
    test "Gralkor is asked to recall memory for the agent's group_id and the thread's session_id with the query" do
      InMemory.set_recall({:ok, nil})

      signal = Signal.new!("ai.react.query", %{query: "new question"}, source: "/test")

      Plugin.handle_signal(signal, context(agent("user-abc", thread_id: "thr-xyz")))

      assert [[group_id, session_id, query]] = InMemory.recalls()
      assert group_id == "user_abc"
      assert session_id == "thr-xyz"
      assert query == "new question"
    end

    test "the thread's session_id is planted on the signal's tool_context for downstream tool calls" do
      InMemory.set_recall({:ok, nil})
      signal = Signal.new!("ai.react.query", %{query: "hi"}, source: "/test")

      assert {:ok, {:continue, %Signal{data: data}}} =
               Plugin.handle_signal(signal, context(agent("user-abc", thread_id: "thr-xyz")))

      assert data.tool_context.session_id == "thr-xyz"
    end

    test "when recall returns a memory block, the turn's query is enriched by prepending the memory block" do
      InMemory.set_recall({:ok, "<gralkor-memory>remembered facts</gralkor-memory>"})
      signal = Signal.new!("ai.react.query", %{query: "hello"}, source: "/test")

      assert {:ok, {:continue, %Signal{data: new_data} = new_signal}} =
               Plugin.handle_signal(signal, context(agent("user-01", thread_id: "thr-1")))

      assert new_signal.type == "ai.react.query"
      assert new_data.query == "<gralkor-memory>remembered facts</gralkor-memory>\n\nhello"
    end

    test "when recall returns nothing, the turn's query passes through unchanged aside from the injected session_id" do
      InMemory.set_recall({:ok, nil})
      signal = Signal.new!("ai.react.query", %{query: "hello"}, source: "/test")

      assert {:ok, {:continue, %Signal{data: data}}} =
               Plugin.handle_signal(signal, context(agent("user-01", thread_id: "thr-1")))

      assert data.query == "hello"
      assert data.tool_context.session_id == "thr-1"
    end

    test "if recall fails, the callback raises so the caller sees the real error" do
      InMemory.set_recall({:error, :gralkor_unreachable})
      signal = Signal.new!("ai.react.query", %{query: "hello"}, source: "/test")

      assert_raise RuntimeError, ~r/Gralkor recall failed.*gralkor_unreachable/, fn ->
        Plugin.handle_signal(signal, context(agent("user-01", thread_id: "thr-1")))
      end
    end

    test "on the very first query of a fresh agent (no thread committed), recall is skipped and a warning is logged" do
      InMemory.set_recall({:ok, "should not be returned"})
      signal = Signal.new!("ai.react.query", %{query: "hello"}, source: "/test")

      log =
        capture_log(fn ->
          assert {:ok, :continue} =
                   Plugin.handle_signal(signal, context(agent("user-01", thread_id: nil)))
        end)

      assert InMemory.recalls() == []
      assert log =~ "[jido_gralkor] skipping recall"
      assert log =~ "user-01"
      assert log =~ "JIDO_CHANGE_SUGGESTIONS.md"
    end
  end

  describe "when an agent turn completes" do
    test "the turn is sent to Gralkor for capture as canonical messages with the thread's session_id and the principal's group_id" do
      InMemory.set_capture(:ok)

      events = [
        %{kind: :llm_completed, data: %{text: "thinking"}},
        %{kind: :tool_completed, data: %{tool_name: "memory_search", result: "..."}}
      ]

      request_id = "req-xyz"

      ag =
        agent("user-42",
          thread_id: "thr-42",
          request_traces: %{request_id => %{events: events, truncated?: false}},
          requests: %{
            request_id => %{query: "what did I say?", status: :pending, result: nil}
          }
        )

      signal =
        Signal.new!(
          "ai.request.completed",
          %{request_id: request_id, result: "you said hi"},
          source: "/test"
        )

      assert {:ok, :continue} = Plugin.handle_signal(signal, context(ag))

      assert [[session_id, group_id, messages]] = InMemory.captures()
      assert session_id == "thr-42"
      assert group_id == "user_42"
      assert [%Message{role: "user", content: "what did I say?"} | rest] = messages
      assert Enum.any?(rest, &match?(%Message{role: "behaviour"}, &1))
      assert List.last(messages) == %Message{role: "assistant", content: "you said hi"}
    end

    test "when the turn's query was enriched with a memory block earlier in the turn, the captured user content strips that block so the episode body records the user's original request" do
      InMemory.set_capture(:ok)
      request_id = "req-enriched"

      original_query = "(User's name: Eli.)\n\nI'm just testing automatic injection."

      enriched_query =
        "<gralkor-memory trust=\"untrusted\">\nFacts:\n- Eli witnessed Lance Franklin kick his 100th goal.\n</gralkor-memory>\n\n" <>
          original_query

      ag =
        agent("user-42",
          thread_id: "thr-42",
          request_traces: %{
            request_id => %{events: [%{kind: :llm_completed, data: %{}}], truncated?: false}
          },
          requests: %{request_id => %{query: enriched_query, status: :pending, result: nil}}
        )

      signal =
        Signal.new!(
          "ai.request.completed",
          %{request_id: request_id, result: "a"},
          source: "/test"
        )

      assert {:ok, :continue} = Plugin.handle_signal(signal, context(ag))

      assert [[_session_id, _group_id, messages]] = InMemory.captures()
      user_msg = Enum.find(messages, &(&1.role == "user"))
      assert user_msg.content == original_query
      refute user_msg.content =~ "<gralkor-memory"
    end
  end

  describe "when an agent turn fails" do
    test "the turn is captured with the failure surfaced as a terminal 'request failed: …' behaviour message" do
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

      assert [[session_id, _group_id, messages]] = InMemory.captures()
      assert session_id == "thr-fail"

      user_msg = Enum.find(messages, &(&1.role == "user"))
      assert user_msg.content == "original question"

      assert List.last(messages) == %Message{
               role: "behaviour",
               content: "request failed: :boom"
             }

      refute Enum.any?(messages, &(&1.role == "assistant"))
    end

    test "first-turn failure with no thread committed skips capture and logs a warning" do
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
        capture_log(fn ->
          assert {:ok, :continue} = Plugin.handle_signal(signal, context(ag))
        end)

      assert InMemory.captures() == []
      assert log =~ "[jido_gralkor] skipping capture"
      assert log =~ "user-01"
      assert log =~ "JIDO_CHANGE_SUGGESTIONS.md"
    end
  end

  describe "when the completed turn has no events in its request trace" do
    test "no capture is sent" do
      InMemory.set_capture(:ok)
      request_id = "req-empty"

      ag =
        agent("user-01",
          thread_id: "thr-empty",
          request_traces: %{request_id => %{events: [], truncated?: false}},
          requests: %{request_id => %{query: "q", status: :pending, result: nil}}
        )

      signal =
        Signal.new!("ai.request.completed", %{request_id: request_id, result: "a"}, source: "/test")

      Plugin.handle_signal(signal, context(ag))

      assert InMemory.captures() == []
    end
  end

  describe "if capture fails" do
    test "the callback raises" do
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
        Signal.new!("ai.request.completed", %{request_id: request_id, result: "a"}, source: "/test")

      assert_raise RuntimeError, ~r/Gralkor capture failed.*gralkor_unreachable/, fn ->
        Plugin.handle_signal(signal, context(ag))
      end
    end
  end
end
