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

  describe "ex-learn > validation" do
    test "raises when agent_name is blank" do
      assert_raise ArgumentError, fn ->
        Learn.learn(turn(), ok_learn(%{}), "  ", "Eli")
      end
    end

    test "raises when user_name is blank" do
      assert_raise ArgumentError, fn ->
        Learn.learn(turn(), ok_learn(%{}), "Susu", "")
      end
    end
  end

  describe "ex-learn > request shape" do
    test "learn_fn receives a prompt rendering the turn with role labels" do
      capture = fn prompt ->
        send(self(), {:prompt, prompt})
        {:ok, %{problem_kind: "k", approach: "a", success: true, lesson: "l"}}
      end

      Learn.learn(turn(), capture, "Susu", "Eli")

      assert_received {:prompt, prompt}
      assert prompt =~ "Eli: the deploy keeps timing out"
      assert prompt =~ "Susu: (behaviour: thought: the health check waits on a cold cache)"
      assert prompt =~ "Susu: (behaviour: tool inspect_logs → cache miss on first request)"
      assert prompt =~ "Susu: I warmed the cache at boot"
    end

    test "the prompt asks what was learned that enabled solving the problem" do
      capture = fn prompt ->
        send(self(), {:prompt, prompt})
        {:ok, %{problem_kind: "k", approach: "a", success: true, lesson: "l"}}
      end

      Learn.learn(turn(), capture, "Susu", "Eli")
      assert_received {:prompt, prompt}
      assert prompt =~ "learn"
    end
  end

  describe "ex-learn > result" do
    test "builds an AgentLearning from atom-keyed learn_fn output" do
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

    test "normalises string-keyed learn_fn output and coerces success to boolean" do
      record = %{
        "problem_kind" => "deploy timeout",
        "approach" => "warm cache at boot",
        "success" => false,
        "lesson" => "cold caches fail the first health check"
      }

      assert {:ok, %AgentLearning{} = learning} =
               Learn.learn(turn(), ok_learn(record), "Susu", "Eli")

      assert learning.problem_kind == "deploy timeout"
      assert learning.approach == "warm cache at boot"
      assert learning.success == false
      assert learning.lesson == "cold caches fail the first health check"
    end

    test "propagates {:error, reason} from learn_fn" do
      assert {:error, :upstream} =
               Learn.learn(turn(), fn _ -> {:error, :upstream} end, "Susu", "Eli")
    end

    test "raises when learn_fn returns a shape that is neither a record nor an error" do
      assert_raise CaseClauseError, fn ->
        Learn.learn(turn(), fn _ -> :oops end, "Susu", "Eli")
      end
    end
  end

  describe "ex-learn > learn_schema/0" do
    test "declares required problem_kind, approach, success, lesson fields" do
      schema = Learn.learn_schema()
      assert schema[:problem_kind][:type] == :string
      assert schema[:problem_kind][:required] == true
      assert schema[:approach][:type] == :string
      assert schema[:approach][:required] == true
      assert schema[:success][:type] == :boolean
      assert schema[:success][:required] == true
      assert schema[:lesson][:type] == :string
      assert schema[:lesson][:required] == true
      assert schema[:lesson][:doc] =~ "learn"
    end
  end
end
