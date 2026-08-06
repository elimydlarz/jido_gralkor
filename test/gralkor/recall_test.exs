defmodule Gralkor.RecallTest do
  use ExUnit.Case, async: true

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

  describe "when a recall is requested" do
    test "then the query reaches interpretation even when the session conversation does not contain it" do
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

  describe "when no relevant facts are found" do
    test "then an empty graph result produces the no-memories body" do
      assert {:ok, block} =
               Recall.recall("g", "TestAgent", nil, "q", default_opts(search_fn: ok_search([])))

      assert block =~ "No relevant memories found."
      assert block =~ ~r/<gralkor-memory trust="untrusted">/
      assert block =~ "</gralkor-memory>"
    end

    test "and interpretation selecting no facts produces the no-memories body" do
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

  describe "when interpretation selects relevant facts" do
    test "then the memory block lists every interpreted line verbatim and in order" do
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

  describe "when a non-blank session id is supplied" do
    test "then buffered turns are flat-walked in order with user and named-agent labels" do
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

  describe "when a nil session id is supplied" do
    test "then conversation context is empty and the turn buffer is not consulted" do
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

  describe "when a maximum result count is supplied" do
    test "then that count is forwarded to the main search" do
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
  end

  describe "when no maximum result count is supplied" do
    test "then the main search receives the default count of ten" do
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

  describe "when an output token budget is supplied" do
    test "then that budget is forwarded to interpretation" do
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
  end

  describe "when no output token budget is supplied" do
    test "then interpretation receives its default budget of two thousand" do
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

  describe "when a group id contains hyphens" do
    test "then every hyphen is replaced with an underscore before search" do
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

  describe "if the agent name is missing or blank" do
    test "then an argument error is raised" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Recall.recall("g", "", nil, "q", default_opts())
      end

      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Recall.recall("g", nil, nil, "q", default_opts())
      end
    end
  end

  describe "when recall returns a memory block" do
    test "then the block is marked as untrusted and instructs the caller to search again for more detail" do
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

  describe "if the main graph search fails" do
    test "then its failure is returned without manufacturing a memory block" do
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

  describe "while a deadline budget governs recall > if the budget expires before recall returns" do
    test "then a deadline-expired error is returned and a warning names the session and budget" do
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
  end

  describe "while a deadline budget governs recall > if recall finishes within the budget" do
    test "then the memory block is returned normally" do
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

  describe "when recall begins and completes" do
    @tag :capture_log
    test "then call metadata and result timing metrics are logged" do
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

  end

  describe "when recall begins and completes > where interpretation does not run" do
    @tag :capture_log
    test "then the interpretation duration is logged as zero" do
      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          {:ok, _} =
            Recall.recall("g", "TestAgent", nil, "q", default_opts(search_fn: ok_search([])))
        end)

      assert logs =~ "interpret:0"
    end
  end

  describe "where test mode is enabled" do
    setup do
      Application.put_env(:jido_gralkor, :test, true)
      on_exit(fn -> Application.delete_env(:jido_gralkor, :test) end)
      :ok
    end

    @tag :capture_log
    test "then the raw query is logged" do
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
    test "and a returned-facts memory block is logged" do
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
    test "and an empty-result memory block is not logged" do
      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} =
            Recall.recall("g", "TestAgent", "s1", "q", default_opts(search_fn: ok_search([])))
        end)

      refute logs =~ "[gralkor] [test] recall block:"
    end

    @tag :capture_log
    test "and each auxiliary result count and result body is logged" do
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

  describe "where test mode is disabled" do
    @tag :capture_log
    test "then neither the raw query nor memory block is logged" do
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

  describe "where a generalisation search is supplied" do
    test "then it runs alongside the main search and receives at least one third of the main limit" do
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

    test "and successful generalisation facts reach interpretation with regular facts" do
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

  end

  describe "where a generalisation search is supplied > if it fails" do
    test "then it contributes no facts while regular facts remain eligible" do
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

  end

  describe "where a generalisation search is supplied > while it returns no facts" do
    test "then recall proceeds normally" do
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

  describe "where no generalisation search is supplied" do
    test "then no generalisation search is issued" do
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

  describe "where both auxiliary searches outlast their yield" do
    @tag :capture_log
    test "then both are abandoned within one shared five-second window" do
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

      assert elapsed_ms < 7_000,
             "expected both aux searches to share one five-second yield; took #{elapsed_ms}ms"
    end
  end

  describe "when the main result limit is smaller than three" do
    test "then each supplied auxiliary search still receives a limit of one" do
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

  describe "where a learning search is supplied" do
    test "then it runs on every recall over the same group with the raw query and at least one third of the main limit" do
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

    test "and successful learning facts reach interpretation with regular facts" do
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

  end

  describe "where a learning search is supplied > if it fails" do
    test "then it contributes no facts while regular facts remain eligible" do
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

  end

  describe "where a learning search is supplied > while it returns no facts" do
    test "then recall proceeds normally" do
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

  describe "where no learning search is supplied" do
    test "then no learning search is issued" do
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

  describe "where a generalisation search is supplied > if it fails > where a learning search is supplied" do
    test "then successful learning-search facts remain eligible" do
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {:interpreted, prompt})
        {:ok, ["learning — relevant"]}
      end

      assert {:ok, _} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(
                   search_fn: ok_search(["main"]),
                   gen_search_fn: fn _, _, _ -> {:error, :failed} end,
                   learning_search_fn: ok_search(["learning"]),
                   interpret_fn: interpret_fn
                 )
               )

      assert_receive {:interpreted, prompt}
      assert prompt =~ "learning"
    end
  end

  describe "where no generalisation search is supplied > where a learning search is supplied" do
    test "then its successful facts still reach interpretation" do
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {:interpreted, prompt})
        {:ok, ["learning — relevant"]}
      end

      assert {:ok, _} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(
                   search_fn: ok_search(["main"]),
                   learning_search_fn: ok_search(["learning"]),
                   interpret_fn: interpret_fn
                 )
               )

      assert_receive {:interpreted, prompt}
      assert prompt =~ "learning"
    end
  end

  describe "where a learning search is supplied > if it fails > where a generalisation search is supplied" do
    test "then successful generalisation-search facts remain eligible" do
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {:interpreted, prompt})
        {:ok, ["generalisation — relevant"]}
      end

      assert {:ok, _} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(
                   search_fn: ok_search(["main"]),
                   gen_search_fn: ok_search(["generalisation"]),
                   learning_search_fn: fn _, _, _ -> {:error, :failed} end,
                   interpret_fn: interpret_fn
                 )
               )

      assert_receive {:interpreted, prompt}
      assert prompt =~ "generalisation"
    end
  end

  describe "where no learning search is supplied > where a generalisation search is supplied" do
    test "then its successful facts still reach interpretation" do
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {:interpreted, prompt})
        {:ok, ["generalisation — relevant"]}
      end

      assert {:ok, _} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(
                   search_fn: ok_search(["main"]),
                   gen_search_fn: ok_search(["generalisation"]),
                   interpret_fn: interpret_fn
                 )
               )

      assert_receive {:interpreted, prompt}
      assert prompt =~ "generalisation"
    end
  end

  describe "where neither auxiliary search is supplied" do
    test "then the main search is the only search issued" do
      test_pid = self()

      search_fn = fn _, _, _ ->
        send(test_pid, :main_search)
        {:ok, []}
      end

      assert {:ok, _} =
               Recall.recall("g", "TestAgent", nil, "q", default_opts(search_fn: search_fn))

      assert_receive :main_search
      refute_received :auxiliary_search
    end
  end

  describe "where both auxiliary searches outlast the outer deadline" do
    test "then the outer deadline ends recall before the five-second auxiliary window elapses" do
      slow = fn _, _, _ ->
        Process.sleep(30_000)
        {:ok, []}
      end

      {elapsed_us, result} =
        :timer.tc(fn ->
          Recall.recall(
            "g",
            "TestAgent",
            nil,
            "q",
            default_opts(
              search_fn: ok_search(["main"]),
              gen_search_fn: slow,
              learning_search_fn: slow,
              deadline_ms: 50
            )
          )
        end)

      assert result == {:error, :recall_deadline_expired}
      assert div(elapsed_us, 1000) < 1_000
    end
  end

  describe "while a deadline budget governs recall > if the budget expires before recall returns > where upstream is ordinary BEAM work" do
    test "then that work is stopped" do
      test_pid = self()

      search_fn = fn _, _, _ ->
        Process.sleep(200)
        send(test_pid, :search_finished)
        {:ok, []}
      end

      assert {:error, :recall_deadline_expired} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(search_fn: search_fn, deadline_ms: 20)
               )

      refute_receive :search_finished, 300
    end
  end
end
