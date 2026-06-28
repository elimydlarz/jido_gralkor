defmodule Gralkor.DistillTest do
  use ExUnit.Case, async: true

  alias Gralkor.Distill
  alias Gralkor.Message

  describe "ex-format-transcript > per turn" do
    test "user messages render as \"{user_name}: {content}\"" do
      result =
        Distill.format_transcript([[Message.new("user", "hi")]], "Susu", "Eli")

      assert result == "Eli: hi"
    end

    test "assistant messages render as \"{agent_name}: {content}\"" do
      result =
        Distill.format_transcript([[Message.new("assistant", "hello")]], "Susu", "Eli")

      assert result == "Susu: hello"
    end

    test "behaviour messages are dropped — no \"(behaviour: …)\" line" do
      result =
        Distill.format_transcript(
          [
            [
              Message.new("user", "Q"),
              Message.new("behaviour", "secret thinking"),
              Message.new("assistant", "A")
            ]
          ],
          "Susu",
          "Eli"
        )

      assert result == "Eli: Q\nSusu: A"
      refute result =~ "behaviour"
      refute result =~ "secret thinking"
    end
  end

  describe "ex-format-transcript > when a turn has only behaviour messages" do
    test "it contributes no lines" do
      result =
        Distill.format_transcript(
          [
            [Message.new("behaviour", "thinking")],
            [Message.new("user", "Q"), Message.new("assistant", "A")]
          ],
          "Susu",
          "Eli"
        )

      assert result == "Eli: Q\nSusu: A"
    end
  end

  describe "ex-format-transcript > turns are joined with newlines" do
    test "multi-turn transcript" do
      result =
        Distill.format_transcript(
          [
            [Message.new("user", "Q1"), Message.new("assistant", "A1")],
            [Message.new("user", "Q2"), Message.new("assistant", "A2")]
          ],
          "Susu",
          "Eli"
        )

      assert result == "Eli: Q1\nSusu: A1\nEli: Q2\nSusu: A2"
    end
  end

  describe "ex-format-transcript > no LLM is involved" do
    test "rendering is pure — format_transcript/3 takes no distill_fn" do
      IO.inspect(Distill, label: "Distill module")
      IO.inspect(function_exported?(Distill, :format_transcript, 3), label: "3-arg exported?")
      IO.inspect(Distill.__info__(:functions) |> Enum.filter(fn {n, _} -> n == :format_transcript end), label: "exports")
      refute function_exported?(Distill, :format_transcript, 4)
      assert function_exported?(Distill, :format_transcript, 3)
    end
  end

  describe "ex-format-transcript > if agent_name is missing or blank" do
    test "raises ArgumentError on blank agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Distill.format_transcript([[Message.new("user", "Q")]], "", "Eli")
      end
    end

    test "raises ArgumentError on nil agent_name" do
      assert_raise ArgumentError, ~r/agent_name/, fn ->
        Distill.format_transcript([[Message.new("user", "Q")]], nil, "Eli")
      end
    end
  end

  describe "ex-format-transcript > if user_name is missing or blank" do
    test "raises ArgumentError on blank user_name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Distill.format_transcript([[Message.new("user", "Q")]], "Susu", "")
      end
    end

    test "raises ArgumentError on nil user_name" do
      assert_raise ArgumentError, ~r/user_name/, fn ->
        Distill.format_transcript([[Message.new("user", "Q")]], "Susu", nil)
      end
    end
  end
end
