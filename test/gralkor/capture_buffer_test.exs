defmodule Gralkor.CaptureBufferTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gralkor.CaptureBuffer
  alias Gralkor.Destination
  alias Gralkor.Message
  alias Gralkor.Reflection
  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Scheduler

  defmodule EmptyReflectionStore do
    @behaviour Gralkor.Reflection.Store

    @impl true
    def get(_reflection, _operator_id, _artefact_id), do: {:error, :not_found}

    @impl true
    def put(_reflection, _operator_id, _artefact), do: :ok
  end

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

  describe "where captured turns select a Lens > if the operator identifier is missing or blank" do
    test "then a missing identifier raises an argument error before any turn is buffered" do
      assert_raise ArgumentError, ~r/operator_id must be a non-blank string/, fn ->
        CaptureBuffer.append_lens(
          "s",
          nil,
          "Susu",
          "Eli",
          "observations",
          [Message.new("user", "x")]
        )
      end

      assert CaptureBuffer.turns_for("s") == []
    end

    test "then a blank identifier raises an argument error before any turn is buffered" do
      assert_raise ArgumentError, ~r/operator_id must be a non-blank string/, fn ->
        CaptureBuffer.append_lenses(
          "s",
          " \t",
          "Susu",
          "Eli",
          ["observations"],
          [Message.new("user", "x")],
          %{tool_context: %{source: :test}}
        )
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
                 ["observations", "decisions"],
                 turn
               )

      assert :ok = CaptureBuffer.flush_and_await("session", 1_000)

      assert_receive {:lens_flushed, "operator-one", "Susu", "Eli", "observations", [^turn]}

      assert_receive {:lens_flushed, "operator-one", "Susu", "Eli", "decisions", [^turn]}
    end

    test "but the session's buffered turns contain that turn only once" do
      turn = [Message.new("user", "one turn")]

      assert :ok =
               CaptureBuffer.append_lenses(
                 "session",
                 "operator-one",
                 "Susu",
                 "Eli",
                 ["observations", "decisions"],
                 turn
               )

      assert [^turn] = CaptureBuffer.turns_for("session")
    end
  end

  describe "where captured turns select a Lens > when later turns contribute Reflection context" do
    test "then nested tool context is merged key by key" do
      restart_with_reflection_capture()

      append_reflection_turn(%{tool_context: %{retained: true, replaced: :old}})
      append_reflection_turn(%{tool_context: %{added: true, replaced: :new}})

      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      assert_receive {:reflections_scheduled, _, ingestion}

      assert ingestion.tool_context == %{retained: true, added: true, replaced: :new}
    end

    test "and later context outside tool context replaces earlier context" do
      restart_with_reflection_capture()

      append_reflection_turn(%{tools: [:old_tool]})
      append_reflection_turn(%{tools: [:new_tool]})

      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      assert_receive {:reflections_scheduled, _, ingestion}

      assert ingestion.tools == [:new_tool]
    end
  end

  describe "where captured turns select a Lens > when Lens-selected turns begin a new buffered ingestion" do
    test "then one ingestion identifier is retained across retries" do
      test_pid = self()
      attempts = :atomics.new(1, [])

      lens_flush_callback = fn _, _, _, lens, _, ingestion_id, evidence_id ->
        attempt = :atomics.add_get(attempts, 1, 1)
        send(test_pid, {:ingestion_attempt, attempt, ingestion_id})

        if attempt == 1 do
          {:error, :temporary}
        else
          {:ok, %{lens: lens, evidence_id: evidence_id, result: :ok}}
        end
      end

      reflection_callback = fn _, ingestion ->
        send(test_pid, {:reflections_scheduled, ingestion})
        :ok
      end

      :ok = stop_supervised(CaptureBuffer)

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: lens_flush_callback,
         reflections: [:daily_summary],
         reflection_callback: reflection_callback,
         retries: [0]}
      )

      append_reflection_turn(%{})
      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)

      assert_receive {:ingestion_attempt, 1, ingestion_id}
      assert_receive {:ingestion_attempt, 2, ^ingestion_id}
      assert_receive {:reflections_scheduled, %{id: ^ingestion_id}}
    end

    test "and identifiers remain collision-resistant across process and VM restarts" do
      restart_with_reflection_capture()
      append_reflection_turn(%{})
      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      assert_receive {:reflections_scheduled, _, first_ingestion}

      restart_with_reflection_capture()
      append_reflection_turn(%{})
      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      assert_receive {:reflections_scheduled, _, second_ingestion}

      assert first_ingestion.id != second_ingestion.id

      assert first_ingestion.id =~
               ~r/^reflection-session:[A-Za-z0-9_-]{22}$/

      assert second_ingestion.id =~
               ~r/^reflection-session:[A-Za-z0-9_-]{22}$/
    end
  end

  describe "where captured turns select a Lens > when every Lens batch for a completed ingestion succeeds and Reflections are declared" do
    test "then every completed representation retains the Lens identity supplied by its batch" do
      restart_with_reflection_capture()

      :ok =
        CaptureBuffer.append_lenses(
          "reflection-session",
          "operator-one",
          "Susu",
          "Eli",
          ["observations", "decisions"],
          [Message.new("user", "remember this")]
        )

      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      assert_receive {:reflections_scheduled, _, ingestion}

      assert Enum.map(ingestion.representations, & &1.lens) == ["observations", "decisions"]
    end

    test "and every completed representation retains the evidence identity supplied by its batch" do
      restart_with_reflection_capture()

      :ok =
        CaptureBuffer.append_lenses(
          "reflection-session",
          "operator-one",
          "Susu",
          "Eli",
          ["observations", "decisions"],
          [Message.new("user", "remember this")]
        )

      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      assert_receive {:reflections_scheduled, _, ingestion}

      assert ingestion.representations |> Enum.map(& &1.evidence_id) |> Enum.uniq() |> length() ==
               1
    end

    test "and every declared Reflection is scheduled exactly once" do
      restart_with_reflection_capture()

      append_reflection_turn(%{tools: [:lookup], tool_context: %{session_id: "thread-one"}})

      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)

      assert_receive {:reflections_scheduled, [:daily_summary, :erl], _ingestion}
      refute_receive {:reflections_scheduled, _, _}
    end

    test "and each scheduled Reflection receives the completed representations" do
      restart_with_reflection_capture()

      append_reflection_turn(%{})

      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      assert_receive {:reflections_scheduled, _, ingestion}
      assert [%{lens: "observations", evidence_id: evidence_id}] = ingestion.representations
      assert is_binary(evidence_id)
    end

    test "and each scheduled Reflection receives the ingestion context" do
      restart_with_reflection_capture()

      append_reflection_turn(%{tools: [:lookup], tool_context: %{session_id: "thread-one"}})

      assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      assert_receive {:reflections_scheduled, _, ingestion}
      assert ingestion.tools == [:lookup]
      assert ingestion.tool_context == %{session_id: "thread-one"}
    end
  end

  describe "where captured turns select a Lens > if a completed representation does not carry its batch's Lens and evidence identity" do
    test "then the awaited flush reports the representation validation failure" do
      restart_with_invalid_representation()
      append_reflection_turn(%{})

      assert {:error, {:representation_lens_mismatch, "observations", "wrong-lens"}} =
               CaptureBuffer.flush_and_await("reflection-session", 1_000)
    end

    test "and no Reflection is scheduled" do
      restart_with_invalid_representation()
      append_reflection_turn(%{})

      assert {:error, _} = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      refute_receive {:reflections_scheduled, _, _}
    end
  end

  describe "where captured turns select a Lens > if Reflection scheduling returns a failure or raises" do
    test "then the scheduling failure is logged" do
      restart_with_scheduling_callback(fn _reflections, _ingestion ->
        {:error, :scheduler_unavailable}
      end)

      append_reflection_turn(%{})

      log =
        capture_log(fn ->
          assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
        end)

      assert log =~ "Reflection scheduling failed"
      assert log =~ ":scheduler_unavailable"
    end

    test "and the successfully completed flush still reports success" do
      restart_with_scheduling_callback(fn _reflections, _ingestion ->
        raise "scheduler unavailable"
      end)

      append_reflection_turn(%{})

      capture_log(fn ->
        assert :ok = CaptureBuffer.flush_and_await("reflection-session", 1_000)
      end)
    end
  end

  describe "when Reflection scheduling needs a scheduler > while one is already running" do
    test "then its registered identity is retained so a supervised replacement remains reachable" do
      :ok = stop_supervised(CaptureBuffer)
      shared_scheduler = start_supervised!(Scheduler)

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: fn _, _, _, _, _, _ -> :ok end,
         reflections: [:daily_summary],
         retries: []}
      )

      assert :sys.get_state(CaptureBuffer).reflection_scheduler == {:shared, Scheduler}
      assert Process.whereis(Scheduler) == shared_scheduler
    end
  end

  describe "when Reflection scheduling needs a scheduler > while declared Reflections use default scheduling and no scheduler is registered" do
    test "then startup fails identifying the required dedicated Reflection supervisor" do
      :ok = stop_supervised(CaptureBuffer)
      Process.flag(:trap_exit, true)

      assert {:error,
              {:reflection_scheduler_unavailable, Gralkor.Reflection.Supervisor}} =
               CaptureBuffer.start_link(
                 flush_callback: fn _, _, _, _, _ -> :ok end,
                 lens_flush_callback: fn _, _, _, _, _, _ -> :ok end,
                 reflections: [:daily_summary],
                 retries: []
               )

      refute Process.whereis(Scheduler)
    end
  end

  describe "when Reflection scheduling needs a scheduler > while no Reflections are declared and no scheduler is registered" do
    test "then the buffer starts without creating a scheduler" do
      assert :ok = stop_supervised(CaptureBuffer)

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: fn _, _, _, _, _, _ -> :ok end,
         reflections: [],
         retries: []}
      )

      assert :sys.get_state(CaptureBuffer).reflection_scheduler == nil
      refute Process.whereis(Scheduler)
    end
  end

  describe "when Reflection scheduling needs a scheduler > while a custom Reflection scheduling callback is supplied and no scheduler is registered" do
    test "then the buffer starts without creating a scheduler" do
      assert :ok = stop_supervised(CaptureBuffer)

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: fn _, _, _, _, _, _ -> :ok end,
         reflections: [:daily_summary],
         reflection_callback: fn _, _ -> :ok end,
         retries: []}
      )

      assert :sys.get_state(CaptureBuffer).reflection_scheduler == nil
      refute Process.whereis(Scheduler)
    end
  end

  describe "when Reflection scheduling needs a scheduler > while the scheduler is shared rather than owned by the buffer" do
    test "then stopping the buffer leaves it running" do
      :ok = stop_supervised(CaptureBuffer)
      shared_scheduler = start_supervised!(Scheduler)

      start_supervised!(
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: fn _, _, _, _, _, _ -> :ok end,
         reflections: [:daily_summary],
         retries: []}
      )

      :ok = stop_supervised(CaptureBuffer)

      assert Process.alive?(shared_scheduler)
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
                 ["observations", "decisions"],
                 turn
               )

      assert :ok = CaptureBuffer.flush("session")
      assert_receive {:lens_attempted, "observations", [^turn]}
      assert_receive {:lens_attempted, "decisions", [^turn]}
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
                 ["observations", "decisions"],
                 turn
               )

      log =
        capture_log(fn ->
          assert {:error, :exhausted} = CaptureBuffer.flush_and_await("session", 1_000)
        end)

      assert_receive {:lens_attempted, "observations", [^turn]}
      assert_receive {:lens_attempted, "decisions", [^turn]}
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

  describe "when a session holding turns is flushed and awaited > while the flush callback fails for any other reason > when the callback throws, exits, or returns a value outside its contract" do
    test "then the outcome is retried as a failure without stopping the buffer" do
      assert_abnormal_callback_outcomes(:awaited)
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

    test "and the call reports success after every session has been attempted" do
      :ok = CaptureBuffer.append("failing", "bad", "Susu", "Eli", nil, [Message.new("user", "x")])
      :ok = CaptureBuffer.append("ok", "g", "Susu", "Eli", nil, [Message.new("user", "y")])

      assert :ok = CaptureBuffer.flush_all()
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

  describe "if the flush callback raises or fails for any other reason > when the callback throws, exits, or returns a value outside its contract" do
    test "then the outcome is retried as a failure without stopping the buffer" do
      assert_abnormal_callback_outcomes(:scheduled)
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

  defp callback_outcome(:throw), do: throw(:boom)
  defp callback_outcome(:exit), do: exit(:boom)
  defp callback_outcome(:unexpected), do: :unexpected

  defp assert_abnormal_callback_outcomes(mode) do
    for outcome <- [:throw, :exit, :unexpected] do
      test_pid = self()
      attempts = :counters.new(1, [])

      flush_callback = fn _g, _a, _u, _o, _t ->
        :counters.add(attempts, 1, 1)
        send(test_pid, {:attempt, outcome, :counters.get(attempts, 1)})
        callback_outcome(outcome)
      end

      :ok = stop_supervised(CaptureBuffer)

      {:ok, pid} =
        start_supervised({CaptureBuffer, flush_callback: flush_callback, retries: [0]})

      session_id = "s-#{outcome}"
      :ok = CaptureBuffer.append(session_id, "g", "Susu", "Eli", nil, [Message.new("user", "x")])

      case mode do
        :awaited ->
          assert {:error, :exhausted} = CaptureBuffer.flush_and_await(session_id, 1_000)

        :scheduled ->
          assert :ok = CaptureBuffer.flush(session_id)
      end

      assert_receive {:attempt, ^outcome, 1}, 200
      assert_receive {:attempt, ^outcome, 2}, 200
      assert Process.alive?(pid)
    end
  end

  defp append_reflection_turn(context) do
    CaptureBuffer.append_lens(
      "reflection-session",
      "operator-one",
      "Susu",
      "Eli",
      "observations",
      [Message.new("user", "remember this")],
      context
    )
  end

  defp restart_with_reflection_capture do
    test_pid = self()

    restart_with_scheduling_callback(fn reflections, ingestion ->
      send(test_pid, {:reflections_scheduled, reflections, ingestion})
      :ok
    end)
  end

  defp restart_with_invalid_representation do
    test_pid = self()

    lens_flush_callback = fn _, _, _, _lens, _, evidence_id ->
      {:ok, %{lens: "wrong-lens", evidence_id: evidence_id}}
    end

    reflection_callback = fn reflections, ingestion ->
      send(test_pid, {:reflections_scheduled, reflections, ingestion})
      :ok
    end

    restart_reflection_buffer(lens_flush_callback, reflection_callback)
  end

  defp restart_with_scheduling_callback(reflection_callback) do
    lens_flush_callback = fn _, _, _, lens, _, evidence_id ->
      {:ok, %{lens: lens, evidence_id: evidence_id, result: :ok}}
    end

    restart_reflection_buffer(lens_flush_callback, reflection_callback)
  end

  defp restart_reflection_buffer(lens_flush_callback, reflection_callback) do
    :ok = stop_supervised(CaptureBuffer)

    start_supervised!(
      {CaptureBuffer,
       flush_callback: fn _, _, _, _, _ -> :ok end,
       lens_flush_callback: lens_flush_callback,
       reflections: [:daily_summary, :erl],
       reflection_callback: reflection_callback,
       retries: []}
    )
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

    test "then an already-started fire-and-forget Lens flush finishes before termination returns" do
      test_pid = self()

      lens_flush_callback = fn _operator,
                               _agent,
                               _user,
                               lens,
                               _turns,
                               _ingestion_id,
                               evidence_id ->
        send(test_pid, {:fire_and_forget_started, self()})

        receive do
          :finish_flush ->
            {:ok, %{lens: lens, evidence_id: evidence_id, result: :ok}}
        end
      end

      reflection_callback = fn _reflections, _ingestion ->
        send(test_pid, :reflection_admitted)
        {:ok, :scheduled}
      end

      :ok = stop_supervised(CaptureBuffer)

      {:ok, pid} =
        start_supervised(
          {CaptureBuffer,
           flush_callback: fn _, _, _, _, _ -> :ok end,
           lens_flush_callback: lens_flush_callback,
           reflections: [:review],
           reflection_callback: reflection_callback,
           retries: []}
        )

      :ok =
        CaptureBuffer.append_lens(
          "s1",
          "operator-one",
          "Susu",
          "Eli",
          "observations",
          [Message.new("user", "remember")]
        )

      :ok = CaptureBuffer.flush("s1")
      assert_receive {:fire_and_forget_started, worker}

      stopper = Task.async(fn -> GenServer.stop(pid, :normal, :infinity) end)
      assert Task.yield(stopper, 25) == nil
      send(worker, :finish_flush)
      assert_receive :reflection_admitted
      assert :ok = Task.await(stopper)
    end

    test "then a buffer started without Reflections still drains directly admitted work" do
      test_pid = self()
      :ok = stop_supervised(CaptureBuffer)

      runner = fn reflection, _ingestion, opts ->
        send(test_pid, :empty_registry_runner_started)
        Process.sleep(100)
        {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{"done" => true}, [])}
      end

      children = [
        {Gralkor.Reflection.Supervisor,
         scheduler_opts: [
           runner: runner,
           store_opts: [storage: EmptyReflectionStore],
           notify: test_pid,
           retry_delays: []
         ]},
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: fn _, _, _, _, _, _ -> :ok end,
         reflections: [],
         retries: []}
      ]

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
      buffer = Process.whereis(CaptureBuffer)

      assert :sys.get_state(buffer).reflection_scheduler == {:shared, Scheduler}

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection()], completed_ingestion())

      assert_receive :empty_registry_runner_started
      stopper = Task.async(fn -> Supervisor.terminate_child(supervisor, CaptureBuffer) end)
      assert Task.yield(stopper, 25) == nil
      assert :ok = Task.await(stopper)
      assert_receive {:reflection_completed, "review", {:ok, _artefact}}
      assert :ok = Supervisor.stop(supervisor)
    end

    test "then a Scheduler crash during drain waits for and drains its supervised replacement" do
      test_pid = self()
      :ok = stop_supervised(CaptureBuffer)
      attempts = :atomics.new(1, [])

      journal_path =
        Path.join(
          System.tmp_dir!(),
          "capture-drain-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}.dets"
        )

      on_exit(fn -> File.rm(journal_path) end)

      runner = fn reflection, _ingestion, opts ->
        attempt = :atomics.add_get(attempts, 1, 1)
        send(test_pid, {:replacement_drain_runner, attempt, self()})

        if attempt == 1 do
          receive do
            :never -> {:error, :unexpected}
          end
        else
          {:ok, Artefact.new(opts[:artefact_id], reflection.name, %{"done" => true}, [])}
        end
      end

      children = [
        {Gralkor.Reflection.Supervisor,
         scheduler_opts: [
           runner: runner,
           store_opts: [storage: EmptyReflectionStore],
           retry_delays: [0],
           journal_path: journal_path
         ]},
        {CaptureBuffer,
         flush_callback: fn _, _, _, _, _ -> :ok end,
         lens_flush_callback: fn _, _, _, _, _, _ -> :ok end,
         reflections: [],
         retries: []}
      ]

      {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

      assert {:ok, :scheduled} =
               Scheduler.schedule([reflection()], completed_ingestion())

      assert_receive {:replacement_drain_runner, 1, _first_runner}
      first_scheduler = Process.whereis(Scheduler)
      stopper = Task.async(fn -> Supervisor.terminate_child(supervisor, CaptureBuffer) end)
      assert eventually(fn -> :sys.get_state(Scheduler).draining end)
      Process.exit(first_scheduler, :kill)

      assert eventually(fn -> Process.whereis(Scheduler) not in [nil, first_scheduler] end)
      assert_receive {:replacement_drain_runner, 2, _second_runner}
      assert :ok = Task.await(stopper)
      assert :ok = Supervisor.stop(supervisor)
    end
  end

  defp reflection do
    %Reflection{
      name: "review",
      destination: %Destination{name: "observations"},
      ontology: Gralkor.DefaultOntology,
      chain_of_thought: %ChainOfThought{path: "test", steps: []}
    }
  end

  defp completed_ingestion do
    %{
      id: "capture-buffer-ingestion",
      operator_id: "operator-one",
      intended_lenses: ["observations"],
      completed_lenses: ["observations"],
      representations: [%{lens: "observations", result: :ok}]
    }
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
