defmodule Gralkor.AgentLearningTest do
  use ExUnit.Case, async: true

  alias Gralkor.AgentLearning

  describe "when a learning record is built" do
    test "then it carries the kind of problem approached, the approach taken, whether the approach succeeded, and the lesson learned" do
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

    test "and no field links it to another learning record, so recalling a learning is never a graph traversal" do
      assert AgentLearning.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:approach, :lesson, :problem_kind, :success]
    end
  end

  describe "when a learning record is rendered into the episode body written to the graph" do
    setup do
      learning = %AgentLearning{
        problem_kind: "intermittent deadlock",
        approach: "ordered lock acquisition",
        success: true,
        lesson: "Eli's scheduler acquires locks in declaration order to avoid cycles"
      }

      %{learning: learning}
    end

    test "then the body states the problem kind verbatim, so a problem-kind-seeded hybrid search surfaces it", %{
      learning: learning
    } do
      assert AgentLearning.to_episode(learning) =~ "intermittent deadlock"
    end

    test "and the body carries the approach verbatim", %{learning: learning} do
      assert AgentLearning.to_episode(learning) =~ "ordered lock acquisition"
    end

    test "and the body carries the lesson verbatim, so the domain entities it names stay linkable", %{
      learning: learning
    } do
      assert AgentLearning.to_episode(learning) =~
               "Eli's scheduler acquires locks in declaration order to avoid cycles"
    end
  end

  describe "when a learning record is rendered into the episode body written to the graph > while the record says the approach succeeded" do
    test "then the body states the outcome as having succeeded" do
      assert AgentLearning.to_episode(learning(true)) =~ "succeeded"
    end
  end

  describe "when a learning record is rendered into the episode body written to the graph > while the record says the approach did not succeed" do
    test "then the body states the outcome as not having succeeded" do
      assert AgentLearning.to_episode(learning(false)) =~ "not succeed"
    end

    test "but the body never uses the word \"succeeded\", so the success bias stays unambiguous" do
      refute AgentLearning.to_episode(learning(false)) =~ "succeeded"
    end
  end

  defp learning(success) do
    %AgentLearning{
      problem_kind: "intermittent deadlock",
      approach: "ordered lock acquisition",
      success: success,
      lesson: "Eli's scheduler acquires locks in declaration order to avoid cycles"
    }
  end
end
