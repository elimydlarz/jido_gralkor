defmodule JidoGralkor.CanonicalTest do
  use ExUnit.Case, async: true

  alias Gralkor.Message
  alias JidoGralkor.Canonical

  describe "when a turn is rendered into canonical messages" do
    test "then the user's query becomes the opening user message exactly as given, with no envelope stripping" do
      query = "  <example>kept</example>\n\nactual question  "

      [user | _] = Canonical.to_messages(query, [], {:completed, "a"})

      assert user == Message.new("user", query)
    end

    test "and the messages run user first, then the behaviour trace in order, then the turn's outcome last" do
      events = [
        %{kind: :llm_completed, data: %{text: "first thought", tool_calls: [%{name: "t"}]}},
        %{kind: :tool_completed, data: %{tool_name: "t", result: "r"}},
        %{kind: :llm_completed, data: %{text: "second thought", tool_calls: [%{name: "t"}]}}
      ]

      messages = Canonical.to_messages("q", events, {:completed, "a"})

      assert Enum.map(messages, & &1.role) == [
               "user",
               "behaviour",
               "behaviour",
               "behaviour",
               "assistant"
             ]

      assert Enum.map(messages, & &1.content) == [
               "q",
               "thought: first thought",
               "tool t → r",
               "thought: second thought",
               "a"
             ]
    end
  end

  describe "when a turn is rendered into canonical messages > while the query, the outcome, and the event trace are all empty" do
    test "then nothing is rendered at all, so the caller can skip the write" do
      assert Canonical.to_messages("", [], {:completed, ""}) == []
    end
  end

  describe "when a turn is rendered into canonical messages > while the trace holds a completed llm event that requested tools" do
    test "then it renders as a behaviour message reading `thought: …`" do
      events = [
        %{kind: :llm_completed, data: %{text: "considering options", tool_calls: [%{name: "t"}]}}
      ]

      messages = Canonical.to_messages("q", events, {:completed, "a"})

      assert Enum.any?(messages, fn
               %Message{role: "behaviour", content: "thought: considering options"} -> true
               _ -> false
             end)
    end

  end

  describe "when a turn is rendered into canonical messages > while the trace holds a completed llm event that requested tools > while that event's content is a list of blocks rather than a string" do
    test "then the text parts are concatenated into a single thought" do
      events = [
        %{
          kind: :llm_completed,
          data: %{
            text: [%{type: "text", text: "hello"}, %{type: "text", text: "world"}],
            tool_calls: [%{name: "t"}]
          }
        }
      ]

      behaviour =
        Canonical.to_messages("q", events, {:completed, "a"})
        |> Enum.find(&(&1.role == "behaviour"))

      assert behaviour.content == "thought: hello world"
    end
  end

  describe "when a turn is rendered into canonical messages > while the trace holds a completed llm event that requested no tools" do
    test "then no thought behaviour message is rendered for it" do
      events = [%{kind: :llm_completed, data: %{text: "direct answer", tool_calls: []}}]

      messages = Canonical.to_messages("q", events, {:completed, "direct answer"})

      refute Enum.any?(messages, &(&1.role == "behaviour" and &1.content =~ "thought"))
    end
  end

  describe "when a turn is rendered into canonical messages > while the trace holds a completed tool event" do
    test "then it renders as a behaviour message reading `tool NAME → RESULT`" do
      events = [
        %{
          kind: :tool_completed,
          data: %{
            tool_name: "memory_search",
            result: {:ok, "3 facts"}
          }
        }
      ]

      [_user, behaviour, _assistant] = Canonical.to_messages("q", events, {:completed, "a"})

      assert behaviour.role == "behaviour"
      assert behaviour.content =~ "tool memory_search"
      assert behaviour.content =~ "ok 3 facts"
    end

  end

  describe "when a turn is rendered into canonical messages > while the trace holds events that are not memory-worthy" do
    test "then those events contribute no messages" do
      events = [
        %{kind: :telemetry_ping, data: %{anything: "x"}},
        %{kind: :llm_completed, data: %{text: "kept", tool_calls: [%{name: "t"}]}}
      ]

      behaviours =
        "q"
        |> Canonical.to_messages(events, {:completed, "a"})
        |> Enum.filter(&(&1.role == "behaviour"))

      assert length(behaviours) == 1
      assert hd(behaviours).content == "thought: kept"
    end

  end

  describe "when a turn is rendered into canonical messages > while the turn completed" do
    test "then the completed answer terminates the messages as the assistant message" do
      events = [
        %{kind: :llm_completed, data: %{text: "t", tool_calls: [%{name: "x"}]}},
        %{kind: :tool_completed, data: %{tool_name: "x", result: "r"}}
      ]

      messages = Canonical.to_messages("q", events, {:completed, "a"})
      assert List.last(messages) == Message.new("assistant", "a")
    end
  end

  describe "when a turn is rendered into canonical messages > while the trace holds a completed tool event > while that event carries no result" do
    test "then it renders as `tool NAME` alone, rather than as an arrow pointing at nothing" do
      for result <- [nil, ""] do
        events = [%{kind: :tool_completed, data: %{tool_name: "memory_search", result: result}}]

        [_user, behaviour] = Canonical.to_messages("q", events, {:completed, ""})

        assert behaviour == Message.new("behaviour", "tool memory_search")
      end
    end
  end

  describe "when a turn is rendered into canonical messages > while the turn completed > while the completed answer is empty" do
    test "then no assistant message is emitted" do
      messages = Canonical.to_messages("q", [], {:completed, ""})
      refute Enum.any?(messages, &(&1.role == "assistant"))
    end
  end

  describe "when a turn is rendered into canonical messages > while the turn failed" do
    test "then a terminal behaviour message reading `request failed: …` takes the place of the assistant answer" do
      events = [%{kind: :llm_completed, data: %{text: "trying"}}]

      messages = Canonical.to_messages("q", events, {:failed, :boom})

      assert List.last(messages) == Message.new("behaviour", "request failed: :boom")
    end

    test "and no assistant message is emitted" do
      messages = Canonical.to_messages("q", [], {:failed, :boom})
      refute Enum.any?(messages, &(&1.role == "assistant"))
    end

    test "and the user's query and the behaviour trace still precede that failure message" do
      events = [
        %{kind: :llm_completed, data: %{text: "thinking", tool_calls: [%{name: "t"}]}},
        %{kind: :tool_completed, data: %{tool_name: "t", result: {:error, :nope}}}
      ]

      messages = Canonical.to_messages("q", events, {:failed, :boom})
      roles = Enum.map(messages, & &1.role)

      assert roles == ["user", "behaviour", "behaviour", "behaviour"]
      assert List.last(messages).content == "request failed: :boom"
    end
  end

  describe "when a turn is rendered into canonical messages > while the turn failed > while the failure reason is an error tuple" do
    test "then it is rendered by the same formatter that renders tool results" do
      messages = Canonical.to_messages("q", [], {:failed, {:error, :timeout}})

      assert List.last(messages) == Message.new("behaviour", "request failed: error :timeout")
    end
  end
end
