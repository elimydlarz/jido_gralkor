defmodule Gralkor.RecallTest do
  use ExUnit.Case, async: true

  alias Gralkor.Recall

  defp ok_search(facts), do: fn _g, _q, _max -> {:ok, facts} end

  defp default_opts(extras \\ []) do
    Keyword.merge([search_fn: ok_search([])], extras)
  end

  describe "when no relevant facts are found" do
    test "then an empty graph result produces the no-memories body" do
      assert {:ok, block} =
               Recall.recall("g", "TestAgent", nil, "q", default_opts(search_fn: ok_search([])))

      assert block =~ "No relevant memories found."
      assert block =~ ~r/<gralkor-memory trust="untrusted">/
      assert block =~ "</gralkor-memory>"
    end
  end

  describe "when memory search returns facts" do
    test "then the memory block lists every returned fact verbatim and in order" do
      returned_facts = [
        "X is a thing (created 2020)",
        "Y was deprecated (invalid since 2022)"
      ]

      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(search_fn: ok_search(returned_facts))
               )

      assert block =~ Enum.at(returned_facts, 0)
      assert block =~ Enum.at(returned_facts, 1)

      assert :binary.match(block, Enum.at(returned_facts, 0)) <
               :binary.match(block, Enum.at(returned_facts, 1))
    end

    test "and every returned fact retains its available source wording" do
      source_wording = "according to the migration report filed by Mina"
      fact = "Y was deprecated, #{source_wording}."

      assert {:ok, block} =
               Recall.recall(
                 "g",
                 "TestAgent",
                 nil,
                 "q",
                 default_opts(search_fn: ok_search([fact]))
               )

      assert block =~ fact
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
                 default_opts(search_fn: ok_search(["- f"]))
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
              default_opts(search_fn: ok_search(["- f"]))
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
              default_opts(search_fn: ok_search(["- f"]))
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
              default_opts(search_fn: ok_search(["- f"]))
            )
        end)

      refute logs =~ "[gralkor] [test]"
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
