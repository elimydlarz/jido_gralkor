defmodule Gralkor.DistillTest do
  use ExUnit.Case, async: true

  alias Gralkor.Distill
  alias Gralkor.Message

  describe "when turns are rendered into the transcript body written to the graph" do
    test "then user messages render as \"{user_name}: {content}\"" do
      result =
        Distill.format_transcript([[Message.new("user", "hi")]], "Susu", "Eli")

      assert result == "Eli: hi"
    end

    test "and assistant messages render as \"{agent_name}: {content}\"" do
      result =
        Distill.format_transcript([[Message.new("assistant", "hello")]], "Susu", "Eli")

      assert result == "Susu: hello"
    end

    test "and behaviour messages are dropped, so no reasoning line reaches the transcript" do
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

    test "and the rendered turns are joined with newlines" do
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

    test "and rendering is pure, accepting no LLM caller at all" do
      Code.ensure_loaded!(Distill)

      refute function_exported?(Distill, :format_transcript, 4)
      assert function_exported?(Distill, :format_transcript, 3)
    end
  end

  describe "when turns are rendered into the transcript body written to the graph > when a turn holds only behaviour messages" do
    test "then that turn contributes no lines to the transcript" do
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

  describe "when turns are rendered into the transcript body written to the graph > if the agent name is missing or blank" do
    test "then an argument error naming the agent name is raised" do
      for agent_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/agent_name/, fn ->
          Distill.format_transcript([[Message.new("user", "Q")]], agent_name, "Eli")
        end
      end
    end
  end

  describe "when turns are rendered into the transcript body written to the graph > if the user name is missing or blank" do
    test "then an argument error naming the user name is raised, because a generic user label would collapse every user into one graph node" do
      for user_name <- [nil, ""] do
        assert_raise ArgumentError, ~r/user_name/, fn ->
          Distill.format_transcript([[Message.new("user", "Q")]], "Susu", user_name)
        end
      end
    end
  end
end
