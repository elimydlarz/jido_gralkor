defmodule Gralkor.CaptureBufferTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.CaptureBuffer
  alias Gralkor.Message

  setup do
    test_pid = self()

    flush_callback = fn group_id, agent_name, user_name, ontology, turns ->
      send(test_pid, {:flushed, group_id, agent_name, user_name, ontology, turns})
      :ok
    end

    {:ok, pid} = start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: []})
    %{pid: pid}
  end

  describe "ex-capture-buffer > append/6 when called for a new session_id" do
    test "an entry is created bound to the sanitized group_id, agent_name, user_name, and the turn" do
      msgs = [Message.new("user", "hi")]
      :ok = CaptureBuffer.append("session-1", "group-1", "Susu", "Eli", nil, msgs)

      assert [^msgs] = CaptureBuffer.turns_for("session-1")
    end

    test "the group_id is stored in sanitized form (hyphens → underscores)" do
      :ok = CaptureBuffer.append("s", "with-hyphens", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert_receive {:flushed, "with_hyphens", "Susu", "Eli", nil, _turns}
    end

    test "the agent_name and user_name are forwarded to the flush callback" do
      :ok = CaptureBuffer.append("s", "g", "Gralkor", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert_receive {:flushed, "g", "Gralkor", "Eli", nil, _turns}
    end
  end

  describe "ex-capture-buffer > append/6 when called again for the same session_id" do
    test "the new turn is appended and prior turns remain buffered" do
      t1 = [Message.new("user", "first")]
      t2 = [Message.new("user", "second")]
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, t1)
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, t2)

      assert [^t1, ^t2] = CaptureBuffer.turns_for("s")
    end
  end

  describe "ex-capture-buffer > append/6 when called for multiple session_ids" do
    test "each session_id has an independent entry" do
      :ok = CaptureBuffer.append("a", "g", "Susu", "Eli", nil, [Message.new("user", "a-msg")])
      :ok = CaptureBuffer.append("b", "g", "Susu", "Eli", nil, [Message.new("user", "b-msg")])

      assert [[%Message{content: "a-msg"}]] = CaptureBuffer.turns_for("a")
      assert [[%Message{content: "b-msg"}]] = CaptureBuffer.turns_for("b")
    end
  end

  describe "ex-capture-buffer > append/6 when called for an existing session_id with a different group_id" do
    test "raises (sessions are not re-bindable across groups)" do
      :ok = CaptureBuffer.append("s", "g1", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert_raise ArgumentError, ~r/group/i, fn ->
        CaptureBuffer.append("s", "g2", "Susu", "Eli", nil, [Message.new("user", "y")])
      end
    end
  end

  describe "ex-capture-buffer > append/6 when called for an existing session_id with a different agent_name" do
    test "raises (sessions are not re-bindable across agents)" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert_raise ArgumentError, ~r/agent/i, fn ->
        CaptureBuffer.append("s", "g", "Other", "Eli", nil, [Message.new("user", "y")])
      end
    end
  end

  describe "ex-capture-buffer > append/6 when called for an existing session_id with a different user_name" do
    test "raises (sessions are not re-bindable across users)" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert_raise ArgumentError, ~r/user/i, fn ->
        CaptureBuffer.append("s", "g", "Susu", "Alice", nil, [Message.new("user", "y")])
      end
    end
  end

  describe "ex-capture-buffer > append/6 if agent_name is missing or blank" do
    test "raises ArgumentError on blank agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        CaptureBuffer.append("s", "g", "", "Eli", nil, [Message.new("user", "x")])
      end
    end

    test "raises ArgumentError on nil agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        CaptureBuffer.append("s", "g", nil, "Eli", nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-capture-buffer > append/6 if user_name is missing or blank" do
    test "raises ArgumentError on blank user_name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        CaptureBuffer.append("s", "g", "Susu", "", nil, [Message.new("user", "x")])
      end
    end

    test "raises ArgumentError on nil user_name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        CaptureBuffer.append("s", "g", "Susu", nil, nil, [Message.new("user", "x")])
      end
    end
  end

  describe "ex-capture-buffer > turns_for/1" do
    test "when the session has never been appended to, returns []" do
      assert [] = CaptureBuffer.turns_for("nope")
    end

    test "when the session has been flushed, returns []" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert [] = CaptureBuffer.turns_for("s")
    end
  end

  describe "ex-capture-buffer > flush/1 when called for a session_id with buffered turns" do
    test "the flush callback is scheduled with (group_id, agent_name, user_name, [[Message]]) and the call returns without awaiting" do
      msgs = [Message.new("user", "hi")]
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, msgs)

      :ok = CaptureBuffer.flush("s")

      assert_receive {:flushed, "g", "Susu", "Eli", nil, [^msgs]}, 1_000
    end

    test "the entry is removed from the buffer" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert [] = CaptureBuffer.turns_for("s")
    end

    test "a [gralkor] flush scheduled — session:<id> turns:<n> line is emitted at :info" do
      :ok = CaptureBuffer.append("sess-x", "g", "Susu", "Eli", nil, [Message.new("user", "a")])
      :ok = CaptureBuffer.append("sess-x", "g", "Susu", "Eli", nil, [Message.new("user", "b")])

      log =
        capture_log([level: :info], fn ->
          :ok = CaptureBuffer.flush("sess-x")
          assert_receive {:flushed, _, _, _, _, _}, 1_000
        end)

      assert log =~ "[info]"
      assert log =~ "[gralkor] flush scheduled — session:sess-x turns:2"
    end
  end

  describe "ex-capture-buffer > flush/1 when called for a session_id with no entry" do
    test "returns without scheduling any flush" do
      :ok = CaptureBuffer.flush("never-existed")

      refute_receive {:flushed, _, _, _, _, _}, 100
    end

    test "a [gralkor] flush — session:<id> empty line is emitted at :info" do
      log =
        capture_log([level: :info], fn ->
          :ok = CaptureBuffer.flush("ghost")
        end)

      assert log =~ "[info]"
      assert log =~ "[gralkor] flush — session:ghost empty"
    end
  end

  describe "ex-capture-buffer > flush_and_await/2 when called for a session_id with buffered turns and the flush callback returns :ok within the timeout" do
    test "returns :ok and consumes the entry" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])

      assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)
      assert_receive {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "1"}]]}, 1_000

      assert [] = CaptureBuffer.turns_for("s1")
    end

    test "logs a flush-completed event at :info" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])

      logs =
        capture_log(fn ->
          assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)
        end)

      assert logs =~ "[gralkor] flush_and_await done — session:s1 outcome:ok"
    end
  end

  describe "ex-capture-buffer > flush_and_await/2 when called for a session_id with buffered turns and the flush callback does not return within the timeout" do
    setup do
      test_pid = self()

      slow_callback = fn _g, _a, _u, _o, _t ->
        send(test_pid, :callback_started)
        Process.sleep(5_000)
        :ok
      end

      :ok = stop_supervised(CaptureBuffer)
      {:ok, _} = start_supervised({CaptureBuffer, flush_callback: slow_callback, retries: []})
      :ok
    end

    test "returns {:error, :timeout} and the entry remains available to flush later" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, :timeout} = CaptureBuffer.flush_and_await("s1", 50)
      assert_receive :callback_started, 1_000

      assert [[%Message{content: "x"}]] = CaptureBuffer.turns_for("s1")
    end
  end

  describe "ex-capture-buffer > flush_and_await/2 when called for a session_id with buffered turns and the callback returns a non-retryable error" do
    setup do
      test_pid = self()

      err_callback = fn _g, _a, _u, _o, _t ->
        send(test_pid, :callback_invoked)
        {:error, :capture_client_4xx}
      end

      :ok = stop_supervised(CaptureBuffer)
      {:ok, _} = start_supervised({CaptureBuffer, flush_callback: err_callback, retries: []})
      :ok
    end

    test "propagates the error without retry and consumes the entry" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, :capture_client_4xx} = CaptureBuffer.flush_and_await("s1", 1_000)
      assert_receive :callback_invoked, 500
      assert [] = CaptureBuffer.turns_for("s1")
    end
  end

  describe "ex-capture-buffer > flush_and_await/2 when called for a session_id with no entry" do
    test "returns :ok without scheduling a flush and logs an empty-flush event" do
      logs =
        capture_log(fn ->
          assert :ok = CaptureBuffer.flush_and_await("unknown", 1_000)
        end)

      assert logs =~ "[gralkor] flush_and_await — session:unknown empty"
      refute_receive {:flushed, _, _, _, _, _}, 100
    end
  end

  describe "ex-capture-buffer > flush_all/0" do
    test "when called with pending entries, every entry is flushed and awaited" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])
      :ok = CaptureBuffer.append("s2", "g", "Susu", "Eli", nil, [Message.new("user", "2")])

      :ok = CaptureBuffer.flush_all()

      assert_receive {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "1"}]]}, 1_000
      assert_receive {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "2"}]]}, 1_000
    end

    test "when called with no entries, returns immediately" do
      assert :ok = CaptureBuffer.flush_all()
    end
  end

  describe "ex-capture-buffer > retry schedule" do
    setup do
      test_pid = self()

      attempts = :counters.new(1, [])

      flush_callback = fn _g, _a, _u, _o, _t ->
        n = :counters.get(attempts, 1) + 1
        :counters.add(attempts, 1, 1)
        send(test_pid, {:attempt, n})

        case n do
          1 -> raise "internal: graph write blew up"
          2 -> raise "internal: still bad"
          _ -> :ok
        end
      end

      :ok = stop_supervised(CaptureBuffer)

      {:ok, _} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: [10, 20, 30]})

      :ok
    end

    test "when the flush callback raises an internal error then retries with the configured backoff" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert_receive {:attempt, 1}, 200
      assert_receive {:attempt, 2}, 200
      assert_receive {:attempt, 3}, 200
      refute_receive {:attempt, 4}, 100
    end
  end

  describe "ex-capture-buffer > retry schedule when the flush callback succeeds (first attempt or after retries)" do
    setup do
      flush_callback = fn _g, _a, _u, _o, _t -> :ok end
      :ok = stop_supervised(CaptureBuffer)
      {:ok, _} = start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: []})
      :ok
    end

    test "logs [gralkor] capture flushed — turns:<n> elapsed:<ms> at :info" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "a")])
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "b")])
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "c")])

      log =
        capture_log([level: :info], fn ->
          :ok = CaptureBuffer.flush("s")
          Process.sleep(50)
        end)

      assert log =~ "[info]"
      assert log =~ ~r/\[gralkor\] capture flushed — turns:3 elapsed:\d+ms/
    end
  end

  describe "ex-capture-buffer > retry schedule when 4xx is returned" do
    setup do
      test_pid = self()
      attempts = :counters.new(1, [])

      flush_callback = fn _g, _a, _u, _o, _t ->
        :counters.add(attempts, 1, 1)
        send(test_pid, {:attempt, :counters.get(attempts, 1)})
        {:error, :capture_client_4xx}
      end

      :ok = stop_supervised(CaptureBuffer)

      {:ok, _} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: [10, 20, 30]})

      :ok
    end

    test "does not retry — the call is contract-error and dropped" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert_receive {:attempt, 1}, 200
      refute_receive {:attempt, 2}, 100
    end
  end

  describe "ex-capture-buffer > retry schedule when an upstream-LLM error is returned" do
    setup do
      test_pid = self()
      attempts = :counters.new(1, [])

      flush_callback = fn _g, _a, _u, _o, _t ->
        :counters.add(attempts, 1, 1)
        send(test_pid, {:attempt, :counters.get(attempts, 1)})
        {:error, {:upstream_llm, :rate_limited}}
      end

      :ok = stop_supervised(CaptureBuffer)

      {:ok, _} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: [10, 20, 30]})

      :ok
    end

    test "does not retry — would amplify load on the struggling upstream" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert_receive {:attempt, 1}, 200
      refute_receive {:attempt, 2}, 100
    end
  end

  describe "ex-capture-buffer > retry schedule when the flush callback fails after 3 retries" do
    setup do
      flush_callback = fn _g, _a, _u, _o, _t -> raise "still broken" end
      :ok = stop_supervised(CaptureBuffer)

      {:ok, _} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: [5, 5, 5]})

      :ok
    end

    test "logs [gralkor] capture exhausted at :error and drops" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      log =
        capture_log(fn ->
          :ok = CaptureBuffer.flush("s")
          Process.sleep(80)
        end)

      assert log =~ "[error]"
      assert log =~ "[gralkor] capture exhausted"
    end
  end

  describe "ex-capture-buffer > application shutdown when the supervision tree is stopping" do
    test "Gralkor.CaptureBuffer.terminate/2 drains every pending entry via the flush callback before returning" do
      test_pid = self()

      flush_callback = fn group, agent, user, ontology, turns ->
        send(test_pid, {:flushed, group, agent, user, ontology, turns})
        :ok
      end

      :ok = stop_supervised(CaptureBuffer)

      {:ok, pid} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: []})

      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])
      :ok = CaptureBuffer.append("s2", "g", "Susu", "Eli", nil, [Message.new("user", "2")])

      :ok = stop_supervised(CaptureBuffer)
      refute Process.alive?(pid)

      assert_received {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "1"}]]}
      assert_received {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "2"}]]}
    end
  end
end
