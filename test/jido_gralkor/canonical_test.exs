defmodule JidoGralkor.CanonicalTest do
  use ExUnit.Case, async: true

  alias Gralkor.Message
  alias JidoGralkor.Canonical

  describe "to_messages/3" do
    test "returns [] when both query and answer are empty and there are no events" do
      assert Canonical.to_messages("", [], "") == []
    end

    test "strips <gralkor-memory> envelope from the user query before emitting the user message" do
      query =
        "<gralkor-memory trust=\"untrusted\">\nFacts:\n- leaked\n</gralkor-memory>\n\nactual question"

      [user | _] = Canonical.to_messages(query, [], "a")

      assert user == Message.new("user", "actual question")
    end

    test "emits a 'thought: …' behaviour message for :llm_completed events" do
      events = [%{kind: :llm_completed, data: %{text: "considering options"}}]

      messages = Canonical.to_messages("q", events, "a")

      assert Enum.any?(messages, fn
               %Message{role: "behaviour", content: "thought: considering options"} -> true
               _ -> false
             end)
    end

    test "emits a 'tool NAME(INPUT) → RESULT' behaviour message for :tool_completed events" do
      events = [
        %{
          kind: :tool_completed,
          data: %{
            tool_name: "memory_search",
            input: %{query: "x"},
            result: {:ok, "3 facts"}
          }
        }
      ]

      [_user, behaviour, _assistant] = Canonical.to_messages("q", events, "a")

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
        |> Canonical.to_messages(events, "a")
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
        %{kind: :llm_completed, data: %{text:"kept"}}
      ]

      behaviours =
        "q"
        |> Canonical.to_messages(events, "a")
        |> Enum.filter(&(&1.role == "behaviour"))

      assert length(behaviours) == 1
      assert hd(behaviours).content == "thought: kept"
    end

    test "omits the assistant message when the answer is empty" do
      messages = Canonical.to_messages("q", [], "")
      refute Enum.any?(messages, &(&1.role == "assistant"))
    end

    test "orders messages user → behaviour(s) → assistant" do
      events = [
        %{kind: :llm_completed, data: %{text:"t"}},
        %{kind: :tool_completed, data: %{tool_name: "x", result: "r"}}
      ]

      messages = Canonical.to_messages("q", events, "a")
      roles = Enum.map(messages, & &1.role)

      assert roles == ["user", "behaviour", "behaviour", "assistant"]
    end

    test "handles list-shaped llm content (Anthropic-style blocks) by concatenating text parts" do
      events = [
        %{
          kind: :llm_completed,
          data: %{text:[%{type: "text", text: "hello"}, %{type: "text", text: "world"}]}
        }
      ]

      behaviour = Enum.find(Canonical.to_messages("q", events, "a"), &(&1.role == "behaviour"))
      assert behaviour.content == "thought: hello world"
    end
  end
end
