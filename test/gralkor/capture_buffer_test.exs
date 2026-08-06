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

    lens_flush_callback = fn operator_id, agent_name, user_name, lens, turns ->
      send(test_pid, {:lens_flushed, operator_id, agent_name, user_name, lens, turns})
      :ok
    end

    {:ok, pid} =
      start_supervised(
        {CaptureBuffer,
         flush_callback: flush_callback, lens_flush_callback: lens_flush_callback, retries: []}
      )

    %{pid: pid}
  end

  describe "when a turn is appended for a session that holds none" do
    test "then the turn is buffered and readable back for that session" do
      msgs = [Message.new("user", "hi")]
      :ok = CaptureBuffer.append("session-1", "group-1", "Susu", "Eli", nil, msgs)

      assert [^msgs] = CaptureBuffer.turns_for("session-1")
    end

    test "and it stays buffered until a flush is explicitly requested, the buffer having no idle-flush policy of its own" do
      msgs = [Message.new("user", "hi")]
      :ok = CaptureBuffer.append("session-1", "group-1", "Susu", "Eli", nil, msgs)

      Process.sleep(20)

      assert [^msgs] = CaptureBuffer.turns_for("session-1")
    end

    test "and the entry binds the session to its group, agent name, user name, and ontology, the ontology being a module or nothing" do
      :ok =
        CaptureBuffer.append("s", "g", "Susu", "Eli", FakeOntologyA, [
          Message.new("user", "x")
        ])

      :ok = CaptureBuffer.flush("s")

      assert_receive {:flushed, "g", "Susu", "Eli", FakeOntologyA, _turns}
    end

    test "and the group it binds is the sanitised form of the group supplied" do
      :ok =
        CaptureBuffer.append("s", "with-hyphens", "Susu", "Eli", nil, [Message.new("user", "x")])

      :ok = CaptureBuffer.flush("s")

      assert_receive {:flushed, "with_hyphens", "Susu", "Eli", nil, _turns}
    end

    test "and the bound group, agent name, user name, and ontology are what the flush callback later receives" do
      :ok = CaptureBuffer.append("s", "g", "Gralkor", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert_receive {:flushed, "g", "Gralkor", "Eli", nil, _turns}
    end
  end

  describe "when a further turn is appended for a session that already holds turns" do
    test "then it is buffered after the turns already held, which remain buffered" do
      t1 = [Message.new("user", "first")]
      t2 = [Message.new("user", "second")]
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, t1)
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, t2)

      assert [^t1, ^t2] = CaptureBuffer.turns_for("s")
    end
  end

  describe "when turns are appended for several sessions" do
    test "then each session buffers its own turns independently of the others" do
      :ok = CaptureBuffer.append("a", "g", "Susu", "Eli", nil, [Message.new("user", "a-msg")])
      :ok = CaptureBuffer.append("b", "g", "Susu", "Eli", nil, [Message.new("user", "b-msg")])

      assert [[%Message{content: "a-msg"}]] = CaptureBuffer.turns_for("a")
      assert [[%Message{content: "b-msg"}]] = CaptureBuffer.turns_for("b")
    end
  end

  describe "if a turn is appended for an existing session under a different group" do
    test "then an argument error is raised, a session not being re-bindable across groups" do
      :ok = CaptureBuffer.append("s", "g1", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert_raise ArgumentError, ~r/group/i, fn ->
        CaptureBuffer.append("s", "g2", "Susu", "Eli", nil, [Message.new("user", "y")])
      end
    end
  end

  describe "if a turn is appended for an existing session under a different agent name" do
    test "then an argument error is raised" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert_raise ArgumentError, ~r/agent/i, fn ->
        CaptureBuffer.append("s", "g", "Other", "Eli", nil, [Message.new("user", "y")])
      end
    end
  end

  describe "if a turn is appended for an existing session under a different user name" do
    test "then an argument error is raised, the human's identity being fixed at the session's first append" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert_raise ArgumentError, ~r/user/i, fn ->
        CaptureBuffer.append("s", "g", "Susu", "Alice", nil, [Message.new("user", "y")])
      end
    end
  end

  describe "if a turn is appended for an existing session under a different ontology" do
    test "then an argument error is raised, one episode never mixing entity and edge schemas" do
      :ok =
        CaptureBuffer.append(
          "s",
          "g",
          "Susu",
          "Eli",
          Gralkor.CaptureBufferTest.FakeOntologyA,
          [Message.new("user", "x")]
        )

      assert_raise ArgumentError, ~r/ontology/i, fn ->
        CaptureBuffer.append(
          "s",
          "g",
          "Susu",
          "Eli",
          Gralkor.CaptureBufferTest.FakeOntologyB,
          [Message.new("user", "y")]
        )
      end
    end
  end

  describe "if a turn without a Lens is appended for a session that already holds Lens-selected turns" do
    test "then an argument error is raised before the new turn is buffered, preserving the Lens-selected turns unchanged" do
      lens_turn = [Message.new("user", "lens turn")]

      :ok =
        CaptureBuffer.append_lens(
          "s",
          "operator",
          "Susu",
          "Eli",
          "observations",
          lens_turn
        )

      assert_raise ArgumentError, ~r/Lens-selected/, fn ->
        CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "legacy")])
      end

      assert [^lens_turn] = CaptureBuffer.turns_for("s")
    end
  end

  describe "if the agent name is missing or blank" do
    test "then an argument error is raised" do
      for agent_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          CaptureBuffer.append("s", "g", agent_name, "Eli", nil, [Message.new("user", "x")])
        end
      end
    end
  end

  describe "if the user name is missing or blank" do
    test "then an argument error is raised" do
      for user_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/user_name/, fn ->
          CaptureBuffer.append("s", "g", "Susu", user_name, nil, [Message.new("user", "x")])
        end
      end
    end
  end

  describe "where captured turns select a Lens > if no Lens is selected" do
    test "then an argument error is raised before any turn is buffered" do
      assert_raise ArgumentError, ~r/lenses/, fn ->
        apply(CaptureBuffer, :append_lenses, [
          "s",
          "operator",
          "Susu",
          "Eli",
          [],
          [Message.new("user", "x")]
        ])
      end

      assert CaptureBuffer.turns_for("s") == []
    end
  end

  describe "where captured turns select a Lens > if a selected Lens name is missing or blank" do
    test "then an argument error is raised before any turn is buffered" do
      for lens <- [nil, ""] do
        assert_raise ArgumentError, ~r/lens/, fn ->
          CaptureBuffer.append_lenses("s", "operator", "Susu", "Eli", [lens], [
            Message.new("user", "x")
          ])
        end
      end

      assert CaptureBuffer.turns_for("s") == []
    end
  end

  describe "where captured turns select a Lens > if a turn is appended for an existing session under a different operator" do
    test "then an argument error is raised, a session not being re-bindable across operators" do
      :ok =
        CaptureBuffer.append_lens(
          "session",
          "operator-one",
          "Susu",
          "Eli",
          "observations",
          [Message.new("user", "x")]
        )

      assert_raise ArgumentError, ~r/operator/i, fn ->
        CaptureBuffer.append_lens(
          "session",
          "operator-two",
          "Susu",
          "Eli",
          "observations",
          [Message.new("user", "y")]
        )
      end
    end
  end

  describe "where captured turns select a Lens > if a turn is appended for an existing session under a different agent name" do
    test "then an argument error is raised" do
      :ok =
        CaptureBuffer.append_lens(
          "session",
          "operator-one",
          "Susu",
          "Eli",
          "observations",
          [Message.new("user", "x")]
        )

      assert_raise ArgumentError, ~r/agent/i, fn ->
        CaptureBuffer.append_lens(
          "session",
          "operator-one",
          "Other",
          "Eli",
          "observations",
          [Message.new("user", "y")]
        )
      end
    end
  end

  describe "where captured turns select a Lens > if a turn is appended for an existing session under a different user name" do
    test "then an argument error is raised" do
      :ok =
        CaptureBuffer.append_lens(
          "session",
          "operator-one",
          "Susu",
          "Eli",
          "observations",
          [Message.new("user", "x")]
        )

      assert_raise ArgumentError, ~r/user/i, fn ->
        CaptureBuffer.append_lens(
          "session",
          "operator-one",
          "Susu",
          "Alice",
          "observations",
          [Message.new("user", "y")]
        )
      end
    end
  end

  describe "where captured turns select a Lens > if a Lens-selected turn is appended for a session that already holds turns without a Lens" do
    test "then an argument error is raised before the new turn is buffered, preserving the turns without a Lens unchanged" do
      legacy_turn = [Message.new("user", "legacy turn")]
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, legacy_turn)

      assert_raise ArgumentError, ~r/without a Lens/, fn ->
        CaptureBuffer.append_lens(
          "s",
          "operator",
          "Susu",
          "Eli",
          "observations",
          [Message.new("user", "lens")]
        )
      end

      assert [^legacy_turn] = CaptureBuffer.turns_for("s")
    end
  end

  describe "where captured turns select a Lens > when turns in one session select different Lenses" do
    test "then each turn stays associated with the Lens it selected" do
      observation = [Message.new("user", "an observation")]
      decision = [Message.new("user", "a decision")]

      assert :ok =
               CaptureBuffer.append_lens(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "observations",
                 observation
               )

      assert :ok =
               CaptureBuffer.append_lens(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "decisions",
                 decision
               )

      assert :ok = CaptureBuffer.flush_and_await("session", 1_000)

      assert_receive {:lens_flushed, "operator-one", "Susu", "Eli", "observations",
                      [^observation]}

      assert_receive {:lens_flushed, "operator-one", "Susu", "Eli", "decisions", [^decision]}
    end

    test "and reading the session's turns back returns every turn in append order across Lenses" do
      observation = [Message.new("user", "an observation")]
      decision = [Message.new("user", "a decision")]

      assert :ok =
               CaptureBuffer.append_lens(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "observations",
                 observation
               )

      assert :ok =
               CaptureBuffer.append_lens(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "decisions",
                 decision
               )

      assert [^observation, ^decision] = CaptureBuffer.turns_for("session")
    end
  end

  describe "where captured turns select a Lens > when the session is flushed" do
    test "then the Lens flush callback receives one batch per Lens carrying only that Lens's turns" do
      observation = [Message.new("user", "an observation")]
      decision = [Message.new("user", "a decision")]

      assert :ok =
               CaptureBuffer.append_lens(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "observations",
                 observation
               )

      assert :ok =
               CaptureBuffer.append_lens(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 "decisions",
                 decision
               )

      assert :ok = CaptureBuffer.flush_and_await("session", 1_000)

      assert_receive {:lens_flushed, "operator-one", "Susu", "Eli", "observations",
                      [^observation]}

      assert_receive {:lens_flushed, "operator-one", "Susu", "Eli", "decisions", [^decision]}
    end
  end

  describe "where captured turns select a Lens > when one captured turn is routed through a primary Lens and an additional Lens" do
    test "then every routed Lens receives that turn in its own batch" do
      turn = [Message.new("user", "one turn")]

      assert :ok =
               CaptureBuffer.append_lenses(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 ["observations", "generalisations"],
                 turn
               )

      assert :ok = CaptureBuffer.flush_and_await("session", 1_000)

      assert_receive {:lens_flushed, "operator-one", "Susu", "Eli", "observations", [^turn]}

      assert_receive {:lens_flushed, "operator-one", "Susu", "Eli", "generalisations", [^turn]}
    end

    test "but the session's buffered turns contain that turn only once" do
      turn = [Message.new("user", "one turn")]

      assert :ok =
               CaptureBuffer.append_lenses(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 ["observations", "generalisations"],
                 turn
               )

      assert [^turn] = CaptureBuffer.turns_for("session")
    end
  end

  describe "where captured turns select a Lens > if one Lens's flush fails" do
    test "then every other Lens's batch is still attempted" do
      restart_with_failing_primary()
      turn = [Message.new("user", "one turn")]

      assert :ok =
               CaptureBuffer.append_lenses(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 ["observations", "generalisations"],
                 turn
               )

      assert :ok = CaptureBuffer.flush("session")
      assert_receive {:lens_attempted, "observations", [^turn]}
      assert_receive {:lens_attempted, "generalisations", [^turn]}
    end

    test "and an awaited flush reports the first failure only after every Lens has been attempted" do
      restart_with_failing_primary()
      turn = [Message.new("user", "one turn")]

      assert :ok =
               CaptureBuffer.append_lenses(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 ["observations", "generalisations"],
                 turn
               )

      log =
        capture_log(fn ->
          assert {:error, :exhausted} = CaptureBuffer.flush_and_await("session", 1_000)
        end)

      assert_receive {:lens_attempted, "observations", [^turn]}
      assert_receive {:lens_attempted, "generalisations", [^turn]}
      assert log =~ "outcome:error reason::exhausted"
    end
  end

  describe "when a session's turns are read back before anything has been appended for it" do
    test "then nothing is returned" do
      assert [] = CaptureBuffer.turns_for("nope")
    end
  end

  describe "when a session's turns are read back after it has been flushed" do
    test "then nothing is returned" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert [] = CaptureBuffer.turns_for("s")
    end
  end

  defp restart_with_failing_primary do
    stop_supervised(CaptureBuffer)
    test_pid = self()

    lens_flush_callback = fn _operator_id, _agent_name, _user_name, lens, turns ->
      send(test_pid, {:lens_attempted, lens, turns})
      if lens == "observations", do: {:error, :primary_failed}, else: :ok
    end

    start_supervised!(
      {CaptureBuffer,
       flush_callback: fn _, _, _, _, _ -> :ok end,
       lens_flush_callback: lens_flush_callback,
       retries: []}
    )
  end

  describe "when a session holding turns is flushed without awaiting" do
    test "then the flush callback is scheduled with the session's group, agent name, user name, ontology, and every buffered turn" do
      msgs = [Message.new("user", "hi")]
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, msgs)

      :ok = CaptureBuffer.flush("s")

      assert_receive {:flushed, "g", "Susu", "Eli", nil, [^msgs]}, 1_000
    end

    test "and the call returns without waiting for the scheduled flush" do
      test_pid = self()

      callback = fn _g, _a, _u, _o, _turns ->
        send(test_pid, :started)
        Process.sleep(200)
        :ok
      end

      :ok = stop_supervised(CaptureBuffer)
      {:ok, _} = start_supervised({CaptureBuffer, flush_callback: callback, retries: []})
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      started_at = System.monotonic_time(:millisecond)
      assert :ok = CaptureBuffer.flush("s")
      assert System.monotonic_time(:millisecond) - started_at < 100
      assert_receive :started
    end

    test "and the entry is removed, so reading the session's turns back returns nothing" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.flush("s")

      assert [] = CaptureBuffer.turns_for("s")
    end

    test "and a scheduled-flush line naming the session and its turn count is logged at info, so a successful flush is observable from logs alone" do
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

  describe "when a session holding no turns is flushed without awaiting" do
    test "then no flush is scheduled" do
      :ok = CaptureBuffer.flush("never-existed")

      refute_receive {:flushed, _, _, _, _, _}, 100
    end

    test "and an empty-flush line naming the session is logged at info, so an empty flush is distinguishable from no flush attempted" do
      log =
        capture_log([level: :info], fn ->
          :ok = CaptureBuffer.flush("ghost")
        end)

      assert log =~ "[info]"
      assert log =~ "[gralkor] flush — session:ghost empty"
    end
  end

  describe "when a session holding turns is flushed and awaited > while the flush callback succeeds within the caller's timeout" do
    test "then success is returned" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])

      assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)
      assert_receive {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "1"}]]}, 1_000
    end

    test "and the entry is consumed, so reading the session's turns back returns nothing" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])

      assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)
      assert [] = CaptureBuffer.turns_for("s1")
    end

    test "and a flush-completed event naming the session and its outcome is logged at info" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])

      logs =
        capture_log(fn ->
          assert :ok = CaptureBuffer.flush_and_await("s1", 1_000)
        end)

      assert logs =~ "[gralkor] flush_and_await done — session:s1 outcome:ok"
    end
  end

  describe "when a session holding turns is flushed and awaited > if the flush callback does not finish within the caller's timeout" do
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

    test "then a timeout error is returned" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, :timeout} = CaptureBuffer.flush_and_await("s1", 50)
      assert_receive :callback_started, 1_000
    end

    test "and the buffered turns remain available to flush again" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, :timeout} = CaptureBuffer.flush_and_await("s1", 50)
      assert_receive :callback_started, 1_000
      assert [[%Message{content: "x"}]] = CaptureBuffer.turns_for("s1")
    end

    test "and a timeout event naming the session is logged at warning" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      log =
        capture_log(fn ->
          assert {:error, :timeout} = CaptureBuffer.flush_and_await("s1", 50)
        end)

      assert log =~ "flush_and_await timeout — session:s1"
    end
  end

  describe "when a session holding turns is flushed and awaited > while the flush callback reports a client contract error" do
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

    test "then that error is returned without any retry" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, :capture_client_4xx} = CaptureBuffer.flush_and_await("s1", 1_000)
      assert_receive :callback_invoked, 500
      refute_receive :callback_invoked, 50
    end

    test "and the entry is still consumed" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, :capture_client_4xx} = CaptureBuffer.flush_and_await("s1", 1_000)
      assert [] = CaptureBuffer.turns_for("s1")
    end
  end

  describe "when a session holding turns is flushed and awaited > while the flush callback reports an upstream-LLM error" do
    setup do
      test_pid = self()
      attempts = :counters.new(1, [])

      err_callback = fn _g, _a, _u, _o, _t ->
        :counters.add(attempts, 1, 1)
        send(test_pid, {:attempt, :counters.get(attempts, 1)})
        {:error, {:upstream_llm, :rate_limited}}
      end

      :ok = stop_supervised(CaptureBuffer)

      {:ok, _} =
        start_supervised({CaptureBuffer, flush_callback: err_callback, retries: [10, 20, 30]})

      :ok
    end

    test "then that error is returned without any retry" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, {:upstream_llm, :rate_limited}} =
               CaptureBuffer.flush_and_await("s1", 1_000)

      assert_receive {:attempt, 1}, 200
      refute_receive {:attempt, 2}, 100
    end
  end

  describe "when a session holding turns is flushed and awaited > while the flush callback fails for any other reason" do
    setup do
      flush_callback = fn _g, _a, _u, _o, _t -> raise "internal: still broken" end
      :ok = stop_supervised(CaptureBuffer)

      {:ok, _} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: [50, 50, 50]})

      :ok
    end

    test "then the same configured backoff schedule applies, bounded by the caller's timeout" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, :timeout} = CaptureBuffer.flush_and_await("s1", 80)
    end
  end

  describe "when a session holding turns is flushed and awaited > while the flush callback fails for any other reason > when the retries together outlast that timeout" do
    setup do
      flush_callback = fn _g, _a, _u, _o, _t -> raise "internal: still broken" end
      :ok = stop_supervised(CaptureBuffer)

      {:ok, _} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: [50, 50, 50]})

      :ok
    end

    test "then a timeout error is returned" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      assert {:error, :timeout} = CaptureBuffer.flush_and_await("s1", 30)
    end
  end

  describe "when a session holding no turns is flushed and awaited" do
    test "then success is returned without scheduling any flush" do
      assert :ok = CaptureBuffer.flush_and_await("unknown", 1_000)
      refute_receive {:flushed, _, _, _, _, _}, 100
    end

    test "and an empty-flush event naming the session is logged at info" do
      logs =
        capture_log(fn ->
          assert :ok = CaptureBuffer.flush_and_await("unknown", 1_000)
        end)

      assert logs =~ "[gralkor] flush_and_await — session:unknown empty"
    end
  end

  describe "when every buffered session is flushed at once" do
    test "then each session's turns go through the same flush callback and retry schedule" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])
      :ok = CaptureBuffer.append("s2", "g", "Susu", "Eli", nil, [Message.new("user", "2")])

      :ok = CaptureBuffer.flush_all()

      assert_receive {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "1"}]]}, 1_000
      assert_receive {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "2"}]]}, 1_000
    end

    test "and the call returns only once every one of those flushes has been awaited" do
      :ok = CaptureBuffer.append("s1", "g", "Susu", "Eli", nil, [Message.new("user", "1")])
      assert :ok = CaptureBuffer.flush_all()
      assert_received {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "1"}]]}
    end
  end

  describe "when a flush of every buffered session finds none buffered" do
    test "then the call returns immediately without invoking the flush callback" do
      assert :ok = CaptureBuffer.flush_all()
      refute_receive {:flushed, _, _, _, _, _}
    end
  end

  describe "when every buffered session is flushed at once > if one session's flush fails" do
    setup do
      test_pid = self()

      flush_callback = fn group_id, agent_name, user_name, ontology, turns ->
        if group_id == "bad" do
          {:error, :boom}
        else
          send(test_pid, {:flushed, group_id, agent_name, user_name, ontology, turns})
          :ok
        end
      end

      :ok = stop_supervised(CaptureBuffer)
      {:ok, _} = start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: []})
      :ok
    end

    test "then the other sessions' flushes still complete" do
      :ok = CaptureBuffer.append("failing", "bad", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.append("ok", "g", "Susu", "Eli", nil, [Message.new("user", "y")])

      assert :ok = CaptureBuffer.flush_all()

      assert_receive {:flushed, "g", "Susu", "Eli", nil, [[%Message{content: "y"}]]}, 1_000
    end
  end

  describe "if the flush callback raises or fails for any other reason" do
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

    test "then the flush is retried on the configured backoff schedule, which defaults to 1s, then 2s, then 4s" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      capture_log(fn ->
        :ok = CaptureBuffer.flush("s")

        assert_receive {:attempt, 1}, 200
        assert_receive {:attempt, 2}, 200
        assert_receive {:attempt, 3}, 200
        refute_receive {:attempt, 4}, 100
      end)
    end
  end

  describe "when a scheduled flush's callback succeeds, on its first attempt or after retries" do
    setup do
      flush_callback = fn _g, _a, _u, _o, _t -> :ok end
      :ok = stop_supervised(CaptureBuffer)
      {:ok, _} = start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: []})
      :ok
    end

    test "then a flush-completed line naming the turn count and the elapsed milliseconds is logged at info" do
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

  describe "if the flush callback reports a client contract error" do
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

    test "then the flush is dropped without any retry" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      capture_log(fn ->
        :ok = CaptureBuffer.flush("s")

        assert_receive {:attempt, 1}, 200
        refute_receive {:attempt, 2}, 100
      end)
    end

    test "and a dropped-on-contract-error line is logged at warning" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      log =
        capture_log(fn ->
          :ok = CaptureBuffer.flush("s")
          assert_receive {:attempt, 1}, 200
        end)

      assert log =~ "[warning]"
      assert log =~ "[gralkor] capture dropped (4xx)"
    end
  end

  describe "if the flush callback reports an upstream-LLM error" do
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

    test "then the flush is dropped without any retry, retrying only amplifying load on a struggling upstream" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      capture_log(fn ->
        :ok = CaptureBuffer.flush("s")

        assert_receive {:attempt, 1}, 200
        refute_receive {:attempt, 2}, 100
      end)
    end

    test "and a dropped-on-upstream-error line is logged at warning" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      log =
        capture_log(fn ->
          :ok = CaptureBuffer.flush("s")
          assert_receive {:attempt, 1}, 200
        end)

      assert log =~ "[warning]"
      assert log =~ "[gralkor] capture dropped (upstream error)"
    end
  end

  describe "if the flush callback raises or fails for any other reason > when that schedule is exhausted" do
    setup do
      flush_callback = fn _g, _a, _u, _o, _t -> raise "still broken" end
      :ok = stop_supervised(CaptureBuffer)

      {:ok, _} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: [5, 5, 5]})

      :ok
    end

    test "then the turns are dropped" do
      :ok = CaptureBuffer.append("s", "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      capture_log(fn ->
        :ok = CaptureBuffer.flush("s")
        Process.sleep(80)
      end)

      assert CaptureBuffer.turns_for("s") == []
    end

    test "and an exhausted line is logged at error" do
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

  describe "when a linked flush worker exits normally" do
    test "then nothing is logged for that exit, the flush having already replied",
         %{pid: pid} do
      log =
        capture_log(fn ->
          send(pid, {:EXIT, self(), :normal})
          Process.sleep(20)
        end)

      assert log == ""
    end

    test "and the buffer keeps running", %{pid: pid} do
      send(pid, {:EXIT, self(), :normal})
      Process.sleep(20)
      assert Process.alive?(pid)
    end
  end

  describe "if any other unexpected message arrives, a linked process exiting abnormally included" do
    test "then it is logged at error, so a genuine crash stays observable", %{pid: pid} do
      log =
        capture_log(fn ->
          send(pid, {:EXIT, self(), :boom})
          Process.sleep(20)
        end)

      assert log =~ "[error]"
    end

    test "and the buffer keeps running", %{pid: pid} do
      send(pid, {:EXIT, self(), :boom})
      Process.sleep(20)
      assert Process.alive?(pid)
    end
  end

  describe "when the supervision tree stops the buffer" do
    test "then every pending entry is drained through the flush callback before termination returns" do
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
