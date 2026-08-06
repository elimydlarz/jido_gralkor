defmodule Gralkor.InterpretTest do
  use ExUnit.Case, async: true

  alias Gralkor.Interpret
  alias Gralkor.InterpretParseFailed
  alias Gralkor.Message

  # ── ex-interpret ─────────────────────────────────────────────

  describe "ex-interpret > interpret_facts/6 calls the configured LLM with the prompt" do
    test "the prompt includes the labelled conversation messages and the formatted facts" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {ref, prompt})
        {:ok, []}
      end

      _ =
        Interpret.interpret_facts(
          [Message.new("user", "what about X?")],
          "tell me about X",
          "- X is a thing (created 2020)",
          interpret_fn,
          "Susu"
        )

      assert_receive {^ref, prompt}
      assert prompt =~ "User: what about X?"
      assert prompt =~ "- X is a thing (created 2020)"
    end

    test "the prompt carries the request, so relevance is judged against it even when no conversation carried it" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {ref, prompt})
        {:ok, []}
      end

      _ =
        Interpret.interpret_facts(
          [],
          "Where does Eli work?",
          "- Eli works at Anthropic",
          interpret_fn,
          "Susu"
        )

      assert_receive {^ref, prompt}
      assert prompt =~ "Request to answer:\nWhere does Eli work?"
    end

    test "the prompt gently frames memory as source-derived understanding rather than proven truth" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {ref, prompt})
        {:ok, []}
      end

      _ =
        Interpret.interpret_facts(
          [Message.new("user", "what do we know about X?")],
          "what do we know about X?",
          "- X is a thing",
          interpret_fn,
          "Susu"
        )

      assert_receive {^ref, prompt}
      assert prompt =~ ~r/understandings extracted from source material/i
      assert prompt =~ ~r/rather than proven/i
      assert prompt =~ ~r/mention the source context.*when available.*only where natural/is

      assert prompt =~
               ~r/without confidence labels, truth adjudication, or repetitive uncertainty warnings/i

      assert prompt =~
               ~r/when retrieved memory facts conflict.*return every conflicting account.*never single one out as the true one.*even where the request asks/is
    end
  end

  describe "ex-interpret > interpret_facts/6 when the LLM returns relevant facts" do
    test "returns the list unchanged" do
      facts = [
        "X is a thing (created 2020) — relevant because the user asked about X",
        "Y was deprecated (invalid since 2022) — context for the timeline question"
      ]

      interpret_fn = fn _, _ -> {:ok, facts} end

      assert ^facts =
               Interpret.interpret_facts(
                 [Message.new("user", "tell me about X")],
                 "tell me about X",
                 "- X is a thing\n- Y was deprecated",
                 interpret_fn,
                 "Susu"
               )
    end
  end

  describe "ex-interpret > interpret_facts/6 when the LLM returns an empty list" do
    test "returns []" do
      interpret_fn = fn _, _ -> {:ok, []} end

      assert [] =
               Interpret.interpret_facts(
                 [Message.new("user", "q")],
                 "q",
                 "- nothing relevant",
                 interpret_fn,
                 "Susu"
               )
    end
  end

  describe "ex-interpret > interpret_facts/6 if the LLM response cannot be parsed against the schema" do
    test "raises Gralkor.InterpretParseFailed (a distinct exception; no partial list is returned)" do
      interpret_fn = fn _, _ -> {:ok, %{not: "a list"}} end

      assert_raise InterpretParseFailed, fn ->
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          interpret_fn,
          "Susu"
        )
      end
    end

    test "raises Gralkor.InterpretParseFailed when any list element is not a string" do
      interpret_fn = fn _, _ -> {:ok, ["valid", 123]} end

      assert_raise InterpretParseFailed, fn ->
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          interpret_fn,
          "Susu"
        )
      end
    end

    test "raises RuntimeError when the call returns {:error, _} (upstream LLM failure, distinct from parse failure)" do
      interpret_fn = fn _, _ -> {:error, :upstream} end

      assert_raise RuntimeError, ~r/interpret failed/, fn ->
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          interpret_fn,
          "Susu"
        )
      end
    end
  end

  describe "ex-interpret > interpret_facts/6 if agent_name is missing or blank" do
    test "raises ArgumentError on blank" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          fn _, _ -> {:ok, []} end,
          ""
        )
      end
    end

    test "raises ArgumentError on nil" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          fn _, _ -> {:ok, []} end,
          nil
        )
      end
    end
  end

  describe "ex-interpret > interpret_facts/6 when opts[:output_token_budget] is omitted" do
    test "a default of 2000 is applied (passed to interpret_fn and rendered into the prompt)" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, budget ->
        send(test_pid, {ref, prompt, budget})
        {:ok, []}
      end

      _ =
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          interpret_fn,
          "Susu"
        )

      assert_receive {^ref, prompt, 2000}
      assert prompt =~ "Respond within 2000 tokens"
    end
  end

  describe "ex-interpret > interpret_facts/6 if opts[:output_token_budget] is non-positive or non-integer" do
    test "raises ArgumentError on zero" do
      assert_raise ArgumentError, ~r/output_token_budget/, fn ->
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          fn _, _ -> {:ok, []} end,
          "Susu",
          output_token_budget: 0
        )
      end
    end

    test "raises ArgumentError on negative" do
      assert_raise ArgumentError, ~r/output_token_budget/, fn ->
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          fn _, _ -> {:ok, []} end,
          "Susu",
          output_token_budget: -1
        )
      end
    end

    test "raises ArgumentError on non-integer" do
      assert_raise ArgumentError, ~r/output_token_budget/, fn ->
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          fn _, _ -> {:ok, []} end,
          "Susu",
          output_token_budget: "lots"
        )
      end
    end
  end

  describe "ex-interpret > interpret_facts/6 calls interpret_fn with the prompt AND the output_token_budget" do
    test "interpret_fn receives both the prompt and the configured budget so it can pass max_tokens to the provider" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, budget ->
        send(test_pid, {ref, prompt, budget})
        {:ok, []}
      end

      _ =
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          interpret_fn,
          "Susu",
          output_token_budget: 3500
        )

      assert_receive {^ref, _prompt, 3500}
    end
  end

  describe "ex-interpret > interpret_facts/6 the interpretation prompt carries a budget instruction" do
    test "the prompt includes a 'respond within N tokens' instruction matching the configured budget" do
      ref = make_ref()
      test_pid = self()

      interpret_fn = fn prompt, _budget ->
        send(test_pid, {ref, prompt})
        {:ok, []}
      end

      _ =
        Interpret.interpret_facts(
          [Message.new("user", "q")],
          "q",
          "- f",
          interpret_fn,
          "Susu",
          output_token_budget: 4096
        )

      assert_receive {^ref, prompt}
      assert prompt =~ "Respond within 4096 tokens"
    end
  end

  describe "ex-interpret > the structured-output schema" do
    test "interpret_schema/0 declares relevantFacts as a list of strings" do
      schema = Interpret.interpret_schema()

      assert Keyword.has_key?(schema, :relevantFacts)
      assert schema[:relevantFacts][:type] == {:list, :string}
      assert schema[:relevantFacts][:required] == true
    end

    test "the schema's doc instructs the LLM to copy facts verbatim, preserve timestamps and drop the leading marker" do
      doc = Interpret.interpret_schema()[:relevantFacts][:doc]

      assert doc =~ ~r/verbatim/i
      assert doc =~ ~r/timestamp/i
      assert doc =~ "dropping the leading '- '"
    end

    test "the schema's doc asks for ' — ' and a one-sentence relevance reason after each fact" do
      doc = Interpret.interpret_schema()[:relevantFacts][:doc]

      assert doc =~ "' — '"
      assert doc =~ ~r/one-sentence relevance reason/i
    end
  end

  # ── ex-interpret-context ─────────────────────────────────────

  describe "ex-interpret-context > build_interpretation_context/5" do
    test "labels each message by role: 'User', '{agent_name}' (assistant), '{agent_name}: (behaviour: ...)' (behaviour)" do
      ctx =
        Interpret.build_interpretation_context(
          [
            Message.new("user", "hi"),
            Message.new("behaviour", "thought about it"),
            Message.new("assistant", "hello")
          ],
          "q",
          "- some fact",
          "Susu"
        )

      assert ctx =~ "User: hi"
      assert ctx =~ "Susu: (behaviour: thought about it)"
      assert ctx =~ "Susu: hello"
      refute ctx =~ "Agent did"
      refute ctx =~ "Assistant:"
    end

    test "drops messages with empty cleaned content" do
      ctx =
        Interpret.build_interpretation_context(
          [
            Message.new("user", "hi"),
            Message.new("assistant", "   "),
            Message.new("user", "")
          ],
          "q",
          "- f",
          "Susu"
        )

      refute ctx =~ "Susu:"
      assert ctx |> String.split("User:") |> length() == 2
    end

    test "assembles context as 'Conversation context:\\n{messages}\\n\\nRequest to answer:\\n{query}\\n\\nMemory facts to interpret:\\n{facts}'" do
      ctx =
        Interpret.build_interpretation_context(
          [Message.new("user", "q")],
          "where does Eli work?",
          "- f",
          "Susu"
        )

      assert ctx ==
               "Conversation context:\nUser: q\n\nRequest to answer:\nwhere does Eli work?\n\nMemory facts to interpret:\n- f"
    end

    test "does NOT inspect or mutate content beyond whitespace trimming" do
      preserved =
        "<gralkor-memory trust=\"untrusted\">memory block</gralkor-memory>\nactual content"

      ctx =
        Interpret.build_interpretation_context(
          [Message.new("user", preserved)],
          "q",
          "- f",
          "Susu"
        )

      assert ctx =~ preserved
    end

    test "raises ArgumentError on blank agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Interpret.build_interpretation_context([Message.new("user", "hi")], "q", "- f", "")
      end
    end

    test "raises ArgumentError on nil agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Interpret.build_interpretation_context([Message.new("user", "hi")], "q", "- f", nil)
      end
    end
  end

  describe "ex-interpret-context > where no character budget is supplied" do
    test "then a default of 8000 characters governs the fit" do
      # Measure the fixed overhead a single-message context carries (the
      # template text plus the "User: " prefix) using an explicit, very
      # large budget so nothing gets trimmed. Content length grows the
      # rendered context 1:1, so this pins the exact boundary of the
      # default budget without hardcoding the template's own length.
      uncapped =
        Interpret.build_interpretation_context(
          [Message.new("user", "a")],
          "q",
          "- f",
          "Susu",
          budget: 1_000_000
        )

      overhead = String.length(uncapped) - 1

      fits = 8_000 - overhead
      exceeds = fits + 1

      ctx_fits =
        Interpret.build_interpretation_context(
          [Message.new("user", String.duplicate("a", fits))],
          "q",
          "- f",
          "Susu"
        )

      assert String.length(ctx_fits) == 8_000
      assert ctx_fits =~ "User:"

      ctx_exceeds =
        Interpret.build_interpretation_context(
          [Message.new("user", String.duplicate("a", exceeds))],
          "q",
          "- f",
          "Susu"
        )

      refute ctx_exceeds =~ "User:"
    end
  end

  describe "ex-interpret-context > when total char length exceeds budget" do
    test "oldest messages are dropped until context fits" do
      msgs = [
        Message.new("user", String.duplicate("oldest oldest oldest ", 20)),
        Message.new("assistant", String.duplicate("middle middle middle ", 20)),
        Message.new("user", "newest")
      ]

      ctx = Interpret.build_interpretation_context(msgs, "q", "- f", "Susu", budget: 200)

      assert String.length(ctx) <= 200
      assert ctx =~ "User: newest"
      refute ctx =~ "oldest"
    end

    test "every newer message that fits is retained, not just the newest one" do
      msgs = [
        Message.new("user", String.duplicate("oldest ", 40)),
        Message.new("assistant", "second"),
        Message.new("user", "third"),
        Message.new("assistant", "fourth")
      ]

      ctx = Interpret.build_interpretation_context(msgs, "q", "- f", "Susu", budget: 200)

      assert String.length(ctx) <= 200
      refute ctx =~ "oldest"
      assert ctx =~ "Susu: second"
      assert ctx =~ "User: third"
      assert ctx =~ "Susu: fourth"
    end

    test "if even one message exceeds the budget, the request and the facts are still included" do
      msgs = [Message.new("user", String.duplicate("x", 1000))]

      ctx =
        Interpret.build_interpretation_context(msgs, "still asked", "- f", "Susu", budget: 100)

      refute ctx =~ "User:"
      assert ctx =~ "still asked"
      assert ctx =~ "- f"
    end
  end
end
