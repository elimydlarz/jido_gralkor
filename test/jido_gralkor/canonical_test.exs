defmodule JidoGralkor.CanonicalTest do
  use ExUnit.Case, async: true

  alias Gralkor.Message
  alias JidoGralkor.Canonical

  describe "to_messages/3 — completed turn" do
    test "returns [] when query is empty, answer is empty, and there are no events" do
      assert Canonical.to_messages("", [], {:completed, ""}) == []
    end

    test "strips <gralkor-memory> envelope from the user query before emitting the user message" do
      query =
        "<gralkor-memory trust=\"untrusted\">\nFacts:\n- leaked\n</gralkor-memory>\n\nactual question"

      [user | _] = Canonical.to_messages(query, [], {:completed, "a"})

      assert user == Message.new("user", "actual question")
    end

    test "emits a 'thought: …' behaviour message for :llm_completed events" do
      events = [%{kind: :llm_completed, data: %{text: "considering options"}}]

      messages = Canonical.to_messages("q", events, {:completed, "a"})

      assert Enum.any?(messages, fn
               %Message{role: "behaviour", content: "thought: considering options"} -> true
               _ -> false
             end)
    end

    test "emits a 'tool NAME → RESULT' behaviour message for :tool_completed events" do
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

    test "preserves event order in the emitted behaviour messages" do
      events = [
        %{kind: :llm_completed, data: %{text: "first thought"}},
        %{kind: :tool_completed, data: %{tool_name: "t", result: "r"}},
        %{kind: :llm_completed, data: %{text: "second thought"}}
      ]

      behaviours =
        "q"
        |> Canonical.to_messages(events, {:completed, "a"})
        |> Enum.filter(&(&1.role == "behaviour"))
        |> Enum.map(& &1.content)

      assert behaviours == [
               "thought: first thought",
               "tool t → r",
               "thought: second thought"
             ]
    end

    test "ignores events whose :kind is not memory-worthy" do
      events = [
        %{kind: :telemetry_ping, data: %{anything: "x"}},
        %{kind: :llm_completed, data: %{text: "kept"}}
      ]

      behaviours =
        "q"
        |> Canonical.to_messages(events, {:completed, "a"})
        |> Enum.filter(&(&1.role == "behaviour"))

      assert length(behaviours) == 1
      assert hd(behaviours).content == "thought: kept"
    end

    test "omits the assistant message when the completed answer is empty" do
      messages = Canonical.to_messages("q", [], {:completed, ""})
      refute Enum.any?(messages, &(&1.role == "assistant"))
    end

    test "orders messages user → behaviour(s) → assistant" do
      events = [
        %{kind: :llm_completed, data: %{text: "t"}},
        %{kind: :tool_completed, data: %{tool_name: "x", result: "r"}}
      ]

      messages = Canonical.to_messages("q", events, {:completed, "a"})
      roles = Enum.map(messages, & &1.role)

      assert roles == ["user", "behaviour", "behaviour", "assistant"]
    end

    test "handles list-shaped llm content (Anthropic-style blocks) by concatenating text parts" do
      events = [
        %{
          kind: :llm_completed,
          data: %{text: [%{type: "text", text: "hello"}, %{type: "text", text: "world"}]}
        }
      ]

      behaviour =
        Canonical.to_messages("q", [hd(events)], {:completed, "a"})
        |> Enum.find(&(&1.role == "behaviour"))

      assert behaviour.content == "thought: hello world"
    end
  end

  describe "to_messages/3 — failed turn" do
    test "emits a terminal 'request failed: …' behaviour message in place of the assistant answer" do
      events = [%{kind: :llm_completed, data: %{text: "trying"}}]

      messages = Canonical.to_messages("q", events, {:failed, :boom})

      assert List.last(messages) == Message.new("behaviour", "request failed: :boom")
      refute Enum.any?(messages, &(&1.role == "assistant"))
    end

    test "renders {:error, reason} error terms via the same formatter as tool results" do
      messages = Canonical.to_messages("q", [], {:failed, {:error, :timeout}})

      assert List.last(messages) == Message.new("behaviour", "request failed: error :timeout")
    end

    test "keeps the user query and event trace ahead of the failure marker" do
      events = [
        %{kind: :llm_completed, data: %{text: "thinking"}},
        %{kind: :tool_completed, data: %{tool_name: "t", result: {:error, :nope}}}
      ]

      messages = Canonical.to_messages("q", events, {:failed, :boom})
      roles = Enum.map(messages, & &1.role)

      assert roles == ["user", "behaviour", "behaviour", "behaviour"]
      assert List.last(messages).content == "request failed: :boom"
    end
  end
end
