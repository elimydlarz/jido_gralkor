defmodule Gralkor.InterpretTest do
  use ExUnit.Case, async: true

  alias Gralkor.Interpret
  alias Gralkor.InterpretParseFailed
  alias Gralkor.Message

  describe "when facts are interpreted for a request against a conversation" do
    test "then the prompt sent to the model carries the labelled conversation messages" do
      assert captured_prompt() =~ "User: what about X?"
    end

    test "and the prompt carries the request the facts were recalled for, so relevance is judged against what was asked even when the conversation never carried it" do
      assert captured_prompt() =~ "Request to answer:\ntell me about X"
    end

    test "and the prompt carries the formatted facts" do
      assert captured_prompt() =~ "- X is a thing (created 2020)"
    end

    test "and the prompt frames retrieved facts as understandings extracted from source material rather than proven claims" do
      prompt = captured_prompt()
      assert prompt =~ ~r/understandings extracted from source material/i
      assert prompt =~ ~r/rather than proven/i
    end

    test "and the prompt asks for the source context, when available, to be mentioned only where natural" do
      prompt = captured_prompt()
      assert prompt =~ ~r/mention the source context.*when available.*only where natural/is
    end

    test "and the prompt rules out confidence labels, truth adjudication, and repetitive uncertainty warnings" do
      prompt = captured_prompt()
      assert prompt =~
               ~r/without confidence labels, truth adjudication, or repetitive uncertainty warnings/i
    end

    test "and the prompt asks that conflicting retrieved facts be preserved as separate accounts rather than one being chosen as true" do
      prompt = captured_prompt()
      assert prompt =~
               ~r/when retrieved memory facts conflict.*return every conflicting account.*never single one out as the true one.*even where the request asks/is
    end

    test "and the structured-output schema requires the relevant facts as a list of strings" do
      schema = Interpret.interpret_schema()
      assert schema[:relevantFacts][:type] == {:list, :string}
      assert schema[:relevantFacts][:required] == true
    end

    test "and the schema instructs the model to copy each fact line verbatim, preserving every timestamp parenthetical and dropping the leading \"- \"" do
      doc = Interpret.interpret_schema()[:relevantFacts][:doc]
      assert doc =~ ~r/verbatim/i
      assert doc =~ ~r/timestamp/i
      assert doc =~ "dropping the leading '- '"
    end

    test "and the schema asks for ' — ' and a one-sentence relevance reason after each copied fact" do
      doc = Interpret.interpret_schema()[:relevantFacts][:doc]
      assert doc =~ "' — '"
      assert doc =~ ~r/one-sentence relevance reason/i
    end
  end

  describe "when the model returns relevant facts" do
    test "then the list is returned unchanged" do
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

  describe "when the model returns an empty list" do
    test "then an empty list is returned" do
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

  describe "if the model response is not a list of strings" do
    test "then Gralkor.InterpretParseFailed is raised as a failure distinct from an upstream error" do
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

    test "and no partial list is returned" do
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

    test "and the raised failure carries the response that could not be parsed, so a caller can see what came back" do
      interpret_fn = fn _, _ -> {:ok, %{not: "a list"}} end

      error =
        assert_raise InterpretParseFailed, fn ->
          Interpret.interpret_facts([Message.new("user", "q")], "q", "- f", interpret_fn, "Susu")
        end

      assert error.raw_response == {:ok, %{not: "a list"}}
      assert Exception.message(error) =~ ~s(%{not: "a list"})
    end

  end

  describe "if the model call itself fails" do
    test "then a RuntimeError naming the interpret failure is raised" do
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

  describe "when facts are interpreted for a request against a conversation > if the agent name is missing or blank" do
    test "then an ArgumentError is raised" do
      for agent_name <- ["", nil] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Interpret.interpret_facts(
            [Message.new("user", "q")],
            "q",
            "- f",
            fn _, _ -> {:ok, []} end,
            agent_name
          )
        end
      end
    end
  end

  describe "when no output token budget is supplied" do
    test "then a default of 2000 is passed to the model call" do
      assert {_prompt, 2000} = captured_budget([])
    end

    test "and the prompt instructs the model to respond within 2000 tokens" do
      assert {prompt, 2000} = captured_budget([])
      assert prompt =~ "Respond within 2000 tokens"
    end
  end

  describe "if the output token budget is zero, negative, or not an integer" do
    test "then an ArgumentError is raised" do
      for budget <- [0, -1, "lots"] do
        assert_raise ArgumentError, ~r/output_token_budget/, fn ->
          Interpret.interpret_facts(
            [Message.new("user", "q")],
            "q",
            "- f",
            fn _, _ -> {:ok, []} end,
            "Susu",
            output_token_budget: budget
          )
        end
      end
    end
  end

  describe "when an output token budget is supplied" do
    test "then it is passed to the model call alongside the prompt so a token ceiling can reach the provider" do
      assert {_prompt, 3500} = captured_budget(output_token_budget: 3500)
    end

    test "and the prompt instructs the model to respond within that many tokens" do
      assert {prompt, 4096} = captured_budget(output_token_budget: 4096)
      assert prompt =~ "Respond within 4096 tokens"
    end
  end

  describe "when the interpretation context is built from messages, a request, facts, and an agent name" do
    setup do
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

      %{ctx: ctx}
    end

    test "then user messages render as \"User: {content}\"", %{ctx: ctx} do
      assert ctx =~ "User: hi"
    end

    test "and assistant messages render as \"{agent_name}: {content}\"", %{ctx: ctx} do
      assert ctx =~ "Susu: hello"
      refute ctx =~ "Assistant:"
    end

    test "and behaviour messages render as \"{agent_name}: (behaviour: {content})\"", %{ctx: ctx} do
      assert ctx =~ "Susu: (behaviour: thought about it)"
      refute ctx =~ "Agent did"
    end

    test "and messages whose content is empty once trimmed are dropped" do
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

    test "and the context reads \"Conversation context:\\n{messages}\\n\\nRequest to answer:\\n{query}\\n\\nMemory facts to interpret:\\n{facts}\"" do
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

    test "and message content is neither inspected nor mutated beyond whitespace trimming" do
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

  end

  describe "when the interpretation context is built from messages, a request, facts, and an agent name > if the agent name is missing or blank" do
    test "then an ArgumentError is raised" do
      for agent_name <- ["", nil] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Interpret.build_interpretation_context(
            [Message.new("user", "hi")],
            "q",
            "- f",
            agent_name
          )
        end
      end
    end
  end

  describe "when the interpretation context is built from messages, a request, facts, and an agent name > where no character budget is supplied" do
    test "then a default of 8000 characters governs the fit" do
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

  describe "when the interpretation context is built from messages, a request, facts, and an agent name > when the rendered messages exceed the character budget" do
    test "then the oldest messages are dropped until the context fits" do
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

    test "but the newest messages that fit are retained" do
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

  end

  describe "when the interpretation context is built from messages, a request, facts, and an agent name > if even a single message on its own exceeds the character budget" do
    test "then the conversation context is left empty" do
      msgs = [Message.new("user", String.duplicate("x", 1000))]

      ctx =
        Interpret.build_interpretation_context(msgs, "still asked", "- f", "Susu", budget: 100)

      refute ctx =~ "User:"
    end

    test "but the request and the memory facts are still included" do
      msgs = [Message.new("user", String.duplicate("x", 1000))]

      ctx =
        Interpret.build_interpretation_context(msgs, "still asked", "- f", "Susu", budget: 100)

      assert ctx =~ "still asked"
      assert ctx =~ "- f"
    end
  end

  defp captured_prompt do
    {prompt, _budget} = captured_budget([])
    prompt
  end

  defp captured_budget(opts) do
    ref = make_ref()
    test_pid = self()

    interpret_fn = fn prompt, budget ->
      send(test_pid, {ref, prompt, budget})
      {:ok, []}
    end

    Interpret.interpret_facts(
      [Message.new("user", "what about X?")],
      "tell me about X",
      "- X is a thing (created 2020)",
      interpret_fn,
      "Susu",
      opts
    )

    assert_receive {^ref, prompt, budget}
    {prompt, budget}
  end
end
