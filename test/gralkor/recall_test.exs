defmodule Gralkor.RecallTest do
  use ExUnit.Case, async: true

  require Logger

  alias Gralkor.Message
  alias Gralkor.Recall

  defp ok_search(facts), do: fn _g, _q, _max -> {:ok, facts} end
  defp ok_interpret(list), do: fn _prompt, _budget -> {:ok, list} end
  defp turns_for(turns), do: fn _session_id -> turns end

  defp default_opts(extras \\ []) do
    Keyword.merge(
      [
        search_fn: ok_search([]),
        interpret_fn: ok_interpret([]),
        turns_fn: turns_for([])
      ],
      extras
    )
  end

  describe "ex-recall > when no relevant facts are found" do
    test "memory_block body is 'No relevant memories found.' (search returned empty)" do
      assert {:ok, block} =
               Recall.recall("g", "TestAgent", nil, "q", default_opts(search_fn: ok_search([])))

      assert block =~ "No relevant memories found."
      assert block =~ ~r/<gralkor-memory trust="untrusted">/
      assert block =~ "</gralkor-memory>"
    end

    test "memory_block body is 'No relevant memories found.' (interpret filtered to empty)" do
      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(
                   search_fn: ok_search(["- some fact (created 2020)"]),
                   interpret_fn: ok_interpret([])
                 )
               )

      assert block =~ "No relevant memories found."
    end
  end

  describe "ex-recall > when relevant facts are found" do
    test "memory_block lists them, one per line, verbatim" do
      facts_relevant = [
        "X is a thing (created 2020) — relevant: user asked about X",
        "Y was deprecated (invalid since 2022) — relevant: timeline context"
      ]

      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(
                   search_fn: ok_search(["- X is a thing (created 2020)"]),
                   interpret_fn: ok_interpret(facts_relevant)
                 )
               )

      assert block =~ Enum.at(facts_relevant, 0)
      assert block =~ Enum.at(facts_relevant, 1)
    end
  end

  describe "ex-recall > request shape > when called with a non-blank session_id" do
    test "conversation context is sourced from CaptureBuffer.turns_for(session_id), flat-walked in order with role labels rendered using agent_name" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {ref, prompt})
        {:ok, ["fact — reason"]}
      end

      turns_fn = fn "session-1" ->
        [
          [Message.new("user", "old user msg"), Message.new("assistant", "old asst msg")],
          [Message.new("user", "new user msg")]
        ]
      end

      _ =
        Recall.recall(
          "g",
          "Susu",
          "session-1",
          "q",
          default_opts(
            search_fn: ok_search(["- f"]),
            interpret_fn: interpret_fn,
            turns_fn: turns_fn
          )
        )

      assert_receive {^ref, prompt}
      assert prompt =~ "User: old user msg"
      assert prompt =~ "Susu: old asst msg"
      assert prompt =~ "User: new user msg"
      refute prompt =~ "Assistant:"
    end
  end

  describe "ex-recall > request shape > when called with a nil session_id" do
    test "conversation context is empty AND the buffer is not consulted" do
      called = :counters.new(1, [])

      turns_fn = fn _ ->
        :counters.add(called, 1, 1)
        []
      end

      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {ref, prompt})
        {:ok, ["fact — reason"]}
      end

      _ =
        Recall.recall(
          "g",
          "TestAgent",
          nil,
          "q",
          default_opts(
            search_fn: ok_search(["- f"]),
            interpret_fn: interpret_fn,
            turns_fn: turns_fn
          )
        )

      assert :counters.get(called, 1) == 0
      assert_receive {^ref, prompt}
      assert prompt =~ "Conversation context:\n\n\nMemory facts to interpret:"
    end
  end

  describe "ex-recall > request shape > max_results" do
    test "when called with max_results, that value is forwarded to search" do
      ref = make_ref()
      test_pid = self()

      search_fn = fn _g, _q, max ->
        send(test_pid, {ref, max})
        {:ok, []}
      end

      _ =
        Recall.recall(
          "g",
          "TestAgent",
          nil,
          "q",
          default_opts(search_fn: search_fn, max_results: 5)
        )

      assert_receive {^ref, 5}
    end

    test "when called without max_results, the default 10 is applied" do
      ref = make_ref()
      test_pid = self()

      search_fn = fn _g, _q, max ->
        send(test_pid, {ref, max})
        {:ok, []}
      end

      _ = Recall.recall("g", "TestAgent", nil, "q", default_opts(search_fn: search_fn))

      assert_receive {^ref, 10}
    end
  end

  describe "ex-recall > request shape > output_token_budget" do
    test "when called with an output_token_budget option, it is forwarded to Gralkor.Interpret.interpret_facts" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn _prompt, budget ->
        send(test_pid, {ref, budget})
        {:ok, ["f — r"]}
      end

      _ =
        Recall.recall(
          "g",
          "TestAgent",
          nil,
          "q",
          default_opts(
            search_fn: ok_search(["- f"]),
            interpret_fn: interpret_fn,
            output_token_budget: 4321
          )
        )

      assert_receive {^ref, 4321}
    end

    test "when called without an output_token_budget option, Gralkor.Interpret.interpret_facts applies its default (2000)" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn _prompt, budget ->
        send(test_pid, {ref, budget})
        {:ok, ["f — r"]}
      end

      _ =
        Recall.recall(
          "g",
          "TestAgent",
          nil,
          "q",
          default_opts(
            search_fn: ok_search(["- f"]),
            interpret_fn: interpret_fn
          )
        )

      assert_receive {^ref, 2000}
    end
  end

  describe "ex-recall > request shape > group_id sanitization" do
    test "group_id is sanitized (hyphens → underscores) before use" do
      ref = make_ref()
      test_pid = self()

      search_fn = fn group, _q, _max ->
        send(test_pid, {ref, group})
        {:ok, []}
      end

      _ =
        Recall.recall(
          "with-some-hyphens",
          "TestAgent",
          nil,
          "q",
          default_opts(search_fn: search_fn)
        )

      assert_receive {^ref, "with_some_hyphens"}
    end
  end

  describe "ex-recall > request shape > if agent_name is missing or blank" do
    test "raises ArgumentError on blank agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Recall.recall("g", "", nil, "q", default_opts())
      end
    end

    test "raises ArgumentError on nil agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Recall.recall("g", nil, nil, "q", default_opts())
      end
    end
  end

  describe "ex-recall > orchestration > memory_block envelope" do
    test "wraps body in <gralkor-memory trust='untrusted'> and includes the further-querying instruction" do
      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(
                   search_fn: ok_search(["- f"]),
                   interpret_fn: ok_interpret(["fact — reason"])
                 )
               )

      assert block =~ ~r/^<gralkor-memory trust="untrusted">/
      assert block =~ ~r{</gralkor-memory>$}
      assert block =~ "Search memory"
    end
  end

  describe "ex-recall > recall deadline" do
    test "if the budget is exhausted before the call returns, returns {:error, :recall_deadline_expired}" do
      slow_search = fn _g, _q, _max ->
        Process.sleep(500)
        {:ok, []}
      end

      assert {:error, :recall_deadline_expired} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(search_fn: slow_search, deadline_ms: 50)
               )
    end

    test "completes within the budget when the upstream is fast" do
      assert {:ok, _} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(search_fn: ok_search([]), deadline_ms: 1_000)
               )
    end
  end

  describe "ex-recall > observability" do
    @tag :capture_log
    test "logs at :info on every call" do
      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          {:ok, _} =
            Recall.recall(
              "g",
              "TestAgent",
              "session-1",
              "what is X?",
              default_opts(
                search_fn: ok_search(["- f"]),
                interpret_fn: ok_interpret(["f — r"])
              )
            )
        end)

      assert logs =~ "[gralkor] recall — session:session-1"
      assert logs =~ "queryChars:10"
      assert logs =~ "[gralkor] recall result"
    end

    @tag :capture_log
    test "interpret:0 is reported when interpret_facts was not called (empty search)" do
      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          {:ok, _} =
            Recall.recall("g", "TestAgent", nil, "q", default_opts(search_fn: ok_search([])))
        end)

      assert logs =~ "interpret:0"
    end
  end

  describe "ex-recall > observability > when test mode is enabled" do
    setup do
      Application.put_env(:gralkor_ex, :test, true)
      on_exit(fn -> Application.delete_env(:gralkor_ex, :test) end)
      :ok
    end

    @tag :capture_log
    test "also logs the raw query" do
      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} =
            Recall.recall(
              "g",
              "TestAgent",
              "s1",
              "what is X?",
              default_opts(search_fn: ok_search([]))
            )
        end)

      assert logs =~ "[gralkor] [test] recall query: what is X?"
    end

    @tag :capture_log
    test "when facts are returned, also logs the resulting memory block" do
      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} =
            Recall.recall(
              "g",
              "TestAgent",
              "s1",
              "q",
              default_opts(
                search_fn: ok_search(["- f"]),
                interpret_fn: ok_interpret(["f — r"])
              )
            )
        end)

      assert logs =~ "[gralkor] [test] recall block:"
      assert logs =~ "<gralkor-memory"
    end

    @tag :capture_log
    test "when no facts are returned, does not log the memory block" do
      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} =
            Recall.recall("g", "TestAgent", "s1", "q", default_opts(search_fn: ok_search([])))
        end)

      refute logs =~ "[gralkor] [test] recall block:"
    end
  end

  describe "ex-recall > observability > when test mode is disabled" do
    @tag :capture_log
    test "does not log the raw query or the memory block" do
      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} =
            Recall.recall(
              "g",
              "TestAgent",
              "s1",
              "q",
              default_opts(
                search_fn: ok_search(["- f"]),
                interpret_fn: ok_interpret(["f — r"])
              )
            )
        end)

      refute logs =~ "[gralkor] [test]"
    end
  end
end
