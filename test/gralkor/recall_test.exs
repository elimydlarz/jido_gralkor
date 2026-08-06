defmodule Gralkor.RecallTest do
  use ExUnit.Case, async: true

  require Logger

  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool
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

  describe "ex-recall > when a recall is requested" do
    test "the query reaches interpretation, so relevance is judged against what was asked" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {ref, prompt})
        {:ok, []}
      end

      _ =
        Recall.recall(
          "g",
          "TestAgent",
          "session-1",
          "Where does Eli work?",
          default_opts(
            search_fn: ok_search(["- Eli works at Anthropic"]),
            interpret_fn: interpret_fn,
            turns_fn: turns_for([[Message.new("user", "unrelated earlier turn")]])
          )
        )

      assert_receive {^ref, prompt}
      assert prompt =~ "Where does Eli work?"
    end
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

      assert prompt =~
               "Conversation context:\n\n\nRequest to answer:\nq\n\nMemory facts to interpret:"
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

  describe "ex-recall > orchestration > if the main graph search fails" do
    test "then {:error, reason} is returned" do
      assert {:error, :unavailable} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(search_fn: fn _group, _query, _max -> {:error, :unavailable} end)
               )
    end
  end

  describe "ex-recall > recall deadline" do
    test "if the budget is exhausted before the call returns, returns {:error, :recall_deadline_expired} and logs the expiry as a warning" do
      slow_search = fn _g, _q, _max ->
        Process.sleep(500)
        {:ok, []}
      end

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :recall_deadline_expired} =
                   Recall.recall(
                     "g",
                     "TestAgent",
                     "expiring-session",
                     "q",
                     default_opts(search_fn: slow_search, deadline_ms: 50)
                   )
        end)

      assert logs =~ "recall deadline expired"
      assert logs =~ "session:expiring-session"

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
      assert logs =~ "group:g"
      assert logs =~ "queryChars:10"
      assert logs =~ "max:10"
      assert logs =~ "[gralkor] recall result — 1 facts"
      assert logs =~ "blockChars:"
      assert logs =~ "search:"
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
      Application.put_env(:jido_gralkor, :test, true)
      on_exit(fn -> Application.delete_env(:jido_gralkor, :test) end)
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

    @tag :capture_log
    test "for each auxiliary search that runs, logs how many results it returned and the results themselves" do
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
                gen_search_fn: fn _g, _q, _m -> {:ok, []} end,
                learning_search_fn: fn _g, _q, _m -> {:ok, ["- learning — a lesson"]} end,
                interpret_fn: ok_interpret([])
              )
            )
        end)

      assert logs =~ "[gralkor] [test] recall gen search — 0 result(s)"
      assert logs =~ "[gralkor] [test] recall learning search — 1 result(s)"
      assert logs =~ "- learning — a lesson"
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

  describe "ex-recall > when gen_search_fn is provided" do
    test "gen search runs in parallel alongside the main search" do
      test_pid = self()

      gen_fn = fn _g, _q, max_r ->
        send(test_pid, {:gen_called, max_r})
        {:ok, ["<generalisation> User prefers dark mode (confidence: 0.85) (level: 0)"]}
      end

      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "dark mode",
                 default_opts(
                   search_fn: ok_search(["- some fact (created 2020)"]),
                   interpret_fn: ok_interpret(["- some fact (created 2020) — relevant"]),
                   gen_search_fn: gen_fn,
                   max_results: 10
                 )
               )

      assert_receive {:gen_called, 3}, 500
      assert block =~ "<gralkor-memory"
    end

    test "gen results are combined with regular facts before interpretation" do
      test_pid = self()

      gen_fn = fn _g, _q, _max ->
        {:ok, ["<generalisation> pattern (confidence: 0.9) (level: 1)"]}
      end

      interpret_fn = fn prompt, _budget ->
        if String.contains?(prompt, "<generalisation> pattern"),
          do: send(test_pid, :interpret_saw_gen)

        {:ok, ["- some fact (created 2020) — relevant"]}
      end

      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "query",
                 default_opts(
                   search_fn: ok_search(["- some fact (created 2020)"]),
                   gen_search_fn: gen_fn,
                   interpret_fn: interpret_fn
                 )
               )

      assert_receive :interpret_saw_gen, 500
      assert block =~ "<gralkor-memory"
    end

    test "when gen search fails, recall proceeds with only regular facts" do
      gen_fn = fn _g, _q, _max -> {:error, :gen_down} end

      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "query",
                 default_opts(
                   search_fn: ok_search(["- some fact (created 2020)"]),
                   interpret_fn: ok_interpret(["- some fact (created 2020) — relevant"]),
                   gen_search_fn: gen_fn
                 )
               )

      assert block =~ "<gralkor-memory"
      assert block =~ "some fact"
    end

    test "when gen search returns empty, recall proceeds normally" do
      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "query",
                 default_opts(
                   search_fn: ok_search(["- some fact (created 2020)"]),
                   interpret_fn: ok_interpret(["- some fact (created 2020) — relevant"]),
                   gen_search_fn: fn _g, _q, _max -> {:ok, []} end
                 )
               )

      assert block =~ "<gralkor-memory"
    end
  end

  describe "ex-recall > when gen_search_fn is absent" do
    test "no gen search is performed (backward compatible)" do
      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "query",
                 default_opts()
               )

      assert block =~ "<gralkor-memory"
    end
  end

  describe "ex-recall > when an auxiliary search outlasts its yield" do
    @tag :capture_log
    test "both auxiliary searches are abandoned after five seconds and recall returns the main facts" do
      slow = fn _g, _q, _max ->
        Process.sleep(30_000)
        {:ok, ["- never seen"]}
      end

      {elapsed_us, result} =
        :timer.tc(fn ->
          Recall.recall(
            "g",
            "TestAgent",
            nil,
            "q",
            default_opts(
              search_fn: ok_search(["- main fact"]),
              gen_search_fn: slow,
              learning_search_fn: slow,
              interpret_fn: fn prompt, _budget ->
                send(self(), {:prompt, prompt})
                {:ok, ["- main fact — r"]}
              end,
              deadline_ms: 30_000
            )
          )
        end)

      assert {:ok, block} = result
      assert block =~ "main fact"
      refute block =~ "never seen"

      elapsed_ms = div(elapsed_us, 1000)
      assert elapsed_ms >= 5_000, "expected the aux yield to be waited out; took #{elapsed_ms}ms"

      assert elapsed_ms < 15_000,
             "expected both aux searches to share one five-second yield; took #{elapsed_ms}ms"
    end
  end

  describe "ex-recall > when the main result limit is small" do
    test "an auxiliary search still asks for at least one result" do
      test_pid = self()

      aux = fn _g, _q, max_r ->
        send(test_pid, {:aux_max, max_r})
        {:ok, []}
      end

      assert {:ok, _} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(
                   search_fn: ok_search(["- f"]),
                   gen_search_fn: aux,
                   learning_search_fn: aux,
                   interpret_fn: ok_interpret(["f — r"]),
                   max_results: 1
                 )
               )

      assert_receive {:aux_max, 1}
      assert_receive {:aux_max, 1}
    end
  end

  describe "ex-recall > when a learning_search_fn is provided in opts" do
    test "the learning search runs unconditionally over the same group_id, seeded with the raw user query" do
      test_pid = self()

      search_fn = fn _g, q, max_r ->
        send(test_pid, {:searched, q, max_r})
        {:ok, ["- main fact (created 2020)"]}
      end

      learning_fn = fn _g, q, max_r ->
        send(test_pid, {:learning_searched, q, max_r})
        {:ok, ["- learned: batch the writes (succeeded)"]}
      end

      assert {:ok, _block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "how do I schedule X",
                 default_opts(
                   search_fn: search_fn,
                   interpret_fn: ok_interpret(["- main fact (created 2020) — relevant"]),
                   learning_search_fn: learning_fn,
                   max_results: 9
                 )
               )

      assert_receive {:searched, "how do I schedule X", 9}, 500
      # The learning search is seeded with the RAW user query (no classification),
      # with max_results / 3 (min 1).
      assert_receive {:learning_searched, "how do I schedule X", 3}, 500
    end

    test "learning results are combined with regular facts before interpretation" do
      test_pid = self()

      learning_fn = fn _g, _q, _max ->
        {:ok, ["- learned: batch the writes (succeeded)"]}
      end

      interpret_fn = fn prompt, _budget ->
        if String.contains?(prompt, "learned: batch the writes"),
          do: send(test_pid, :interpret_saw_learning)

        {:ok, ["- main fact (created 2020) — relevant"]}
      end

      assert {:ok, _block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "query",
                 default_opts(
                   search_fn: ok_search(["- main fact (created 2020)"]),
                   learning_search_fn: learning_fn,
                   interpret_fn: interpret_fn
                 )
               )

      assert_receive :interpret_saw_learning, 500
    end

    test "when the learning search fails, recall proceeds with only regular facts" do
      learning_fn = fn _g, _q, _max -> {:error, :search_down} end

      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "query",
                 default_opts(
                   search_fn: ok_search(["- some fact (created 2020)"]),
                   interpret_fn: ok_interpret(["- some fact (created 2020) — relevant"]),
                   learning_search_fn: learning_fn
                 )
               )

      assert block =~ "some fact"
    end

    test "when the learning search returns empty, recall proceeds normally" do
      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "query",
                 default_opts(
                   search_fn: ok_search(["- some fact (created 2020)"]),
                   interpret_fn: ok_interpret(["- some fact (created 2020) — relevant"]),
                   learning_search_fn: fn _g, _q, _max -> {:ok, []} end
                 )
               )

      assert block =~ "<gralkor-memory"
    end
  end

  describe "ex-recall > when learning_search_fn is absent" do
    test "no learning search is performed (backward compatible)" do
      test_pid = self()

      search_fn = fn _g, q, _max ->
        send(test_pid, {:searched, q})
        {:ok, []}
      end

      assert {:ok, _block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "only-query",
                 default_opts(search_fn: search_fn)
               )

      assert_receive {:searched, "only-query"}, 500
      refute_received {:searched, _other}
    end
  end
end
