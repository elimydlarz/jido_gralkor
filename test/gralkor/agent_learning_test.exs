defmodule Gralkor.AgentLearningTest do
  use ExUnit.Case, async: true

  alias Gralkor.AgentLearning

  describe "ex-agent-learning > struct" do
    test "carries problem_kind, approach, success, lesson" do
      learning = %AgentLearning{
        problem_kind: "flaky integration test",
        approach: "isolated the shared GenServer and reset it per test",
        success: true,
        lesson: "global GenServer state must be reset in setup"
      }

      assert learning.problem_kind == "flaky integration test"
      assert learning.approach == "isolated the shared GenServer and reset it per test"
      assert learning.success == true
      assert learning.lesson == "global GenServer state must be reset in setup"
    end

    test "carries exactly the four fields, so no id/parent/link field makes recall a graph traversal" do
      assert AgentLearning.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:approach, :lesson, :problem_kind, :success]
    end
  end

  describe "ex-agent-learning > to_episode/1" do
    setup do
      learning = %AgentLearning{
        problem_kind: "intermittent deadlock",
        approach: "ordered lock acquisition",
        success: true,
        lesson: "Eli's scheduler acquires locks in declaration order to avoid cycles"
      }

      %{learning: learning}
    end

    test "states the problem_kind verbatim so a kind-seeded search surfaces it", %{
      learning: learning
    } do
      assert AgentLearning.to_episode(learning) =~ "intermittent deadlock"
    end

    test "carries the approach and the lesson verbatim", %{learning: learning} do
      body = AgentLearning.to_episode(learning)
      assert body =~ "ordered lock acquisition"
      assert body =~ "Eli's scheduler acquires locks in declaration order to avoid cycles"
    end

    test "states the outcome as succeeded when success is true", %{learning: learning} do
      body = AgentLearning.to_episode(learning)
      assert body =~ "succeeded"
    end

    test "states the outcome as not having succeeded when success is false", %{learning: learning} do
      body = AgentLearning.to_episode(%{learning | success: false})
      assert body =~ "not succeed"
      refute body =~ "succeeded"
    end
  end
end
