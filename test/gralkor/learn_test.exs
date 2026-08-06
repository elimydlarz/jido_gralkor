defmodule Gralkor.LearnTest do
  use ExUnit.Case, async: true

  alias Gralkor.AgentLearning
  alias Gralkor.Learn
  alias Gralkor.Message

  defp turn do
    [
      Message.new("user", "the deploy keeps timing out, can you fix it?"),
      Message.new("behaviour", "thought: the health check waits on a cold cache"),
      Message.new("behaviour", "tool inspect_logs → cache miss on first request"),
      Message.new("assistant", "I warmed the cache at boot; deploys pass now.")
    ]
  end

  defp ok_learn(record), do: fn _prompt -> {:ok, record} end

  describe "when one reasoning turn is learned from > if the agent name is missing or blank" do
    test "then an argument error is raised" do
      assert_raise ArgumentError, fn ->
        Learn.learn(turn(), ok_learn(%{}), "  ", "Eli")
      end
    end
  end

  describe "when one reasoning turn is learned from > if the user name is missing or blank" do
    test "then an argument error is raised, because the lesson names the human and a generic label corrupts the record" do
      assert_raise ArgumentError, fn ->
        Learn.learn(turn(), ok_learn(%{}), "Susu", "")
      end
    end
  end

  describe "when one reasoning turn is learned from" do
    test "then the injected learning caller is asked exactly once, that single call producing the whole record" do
      assert {:ok, %AgentLearning{}} =
               Learn.learn(
                 turn(),
                 fn _prompt ->
                   send(self(), :called)
                   {:ok, %{problem_kind: "k", approach: "a", success: true, lesson: "l"}}
                 end,
                 "Susu",
                 "Eli"
               )

      assert_received :called
      refute_received :called
    end

    test "and the prompt renders each user message as \"{user_name}: {content}\"" do
      prompt = captured_prompt()
      assert prompt =~ "Eli: the deploy keeps timing out"
    end

    test "and the prompt renders each assistant message as \"{agent_name}: {content}\"" do
      prompt = captured_prompt()
      assert prompt =~ "Susu: I warmed the cache at boot"
    end

    test "and the prompt renders each behaviour message as \"{agent_name}: (behaviour: {content})\"" do
      prompt = captured_prompt()
      assert prompt =~ "Susu: (behaviour: thought: the health check waits on a cold cache)"
      assert prompt =~ "Susu: (behaviour: tool inspect_logs → cache miss on first request)"
    end

    test "and the prompt asks what was learned that enabled solving the problem" do
      prompt = captured_prompt()
      assert prompt =~ "learn"
    end
  end

  describe "when one reasoning turn is learned from > while the learning caller returns an atom-keyed record" do
    test "then a learning record carrying the problem kind, the approach, the success flag, and the lesson is returned" do
      record = %{
        problem_kind: "deploy timeout",
        approach: "warm cache at boot",
        success: true,
        lesson: "cold caches fail the first health check"
      }

      assert {:ok, %AgentLearning{} = learning} =
               Learn.learn(turn(), ok_learn(record), "Susu", "Eli")

      assert learning.problem_kind == "deploy timeout"
      assert learning.approach == "warm cache at boot"
      assert learning.success == true
      assert learning.lesson == "cold caches fail the first health check"
    end
  end

  describe "when one reasoning turn is learned from > while the learning caller returns a string-keyed record" do
    setup do
      record = %{
        "problem_kind" => "deploy timeout",
        "approach" => "warm cache at boot",
        "success" => false,
        "lesson" => "cold caches fail the first health check"
      }

      {:ok, learning} = Learn.learn(turn(), ok_learn(record), "Susu", "Eli")
      %{learning: learning}
    end

    test "then its string keys are normalised into a learning record carrying those same four values",
         %{learning: learning} do
      assert %AgentLearning{} = learning
      assert learning.problem_kind == "deploy timeout"
      assert learning.approach == "warm cache at boot"
      assert learning.lesson == "cold caches fail the first health check"
    end

    test "and its success flag is a boolean", %{learning: learning} do
      assert learning.success == false
    end
  end

  describe "when one reasoning turn is learned from > if the learning caller returns an error" do
    test "then that error is returned to the caller unchanged, never swallowed" do
      assert {:error, :upstream} =
               Learn.learn(turn(), fn _ -> {:error, :upstream} end, "Susu", "Eli")
    end
  end

  describe "when one reasoning turn is learned from > if the learning caller returns anything that is neither a record nor an error" do
    test "then the unexpected shape raises rather than being swallowed" do
      assert_raise CaseClauseError, fn ->
        Learn.learn(turn(), fn _ -> :oops end, "Susu", "Eli")
      end
    end
  end

  describe "when the structured-output schema for learning is requested" do
    test "then the problem kind is a required string" do
      schema = Learn.learn_schema()
      assert schema[:problem_kind][:type] == :string
      assert schema[:problem_kind][:required] == true
    end

    test "and the approach is a required string" do
      schema = Learn.learn_schema()
      assert schema[:approach][:type] == :string
      assert schema[:approach][:required] == true
    end

    test "and the success flag is a required boolean" do
      schema = Learn.learn_schema()
      assert schema[:success][:type] == :boolean
      assert schema[:success][:required] == true
    end

    test "and the lesson is a required string" do
      schema = Learn.learn_schema()
      assert schema[:lesson][:type] == :string
      assert schema[:lesson][:required] == true
    end

    test "and the lesson field instructs the model to answer what it learned that enabled it to solve the problem" do
      assert Learn.learn_schema()[:lesson][:doc] =~ "learn"
    end
  end

  defp captured_prompt do
    capture = fn prompt ->
      send(self(), {:prompt, prompt})
      {:ok, %{problem_kind: "k", approach: "a", success: true, lesson: "l"}}
    end

    Learn.learn(turn(), capture, "Susu", "Eli")

    assert_received {:prompt, prompt}
    prompt
  end
end
