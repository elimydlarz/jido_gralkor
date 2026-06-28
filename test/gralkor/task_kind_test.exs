defmodule Gralkor.TaskKindTest do
  use ExUnit.Case, async: true

  alias Gralkor.TaskKind

  describe "ex-task-kind > validation" do
    test "raises when the task text is blank" do
      assert_raise ArgumentError, fn ->
        TaskKind.classify("  ", fn _ -> {:ok, "k"} end)
      end
    end

    test "raises when the task text is missing" do
      assert_raise ArgumentError, fn ->
        TaskKind.classify(nil, fn _ -> {:ok, "k"} end)
      end
    end
  end

  describe "ex-task-kind > request shape" do
    test "classify_fn receives a prompt carrying the task text and asking for the kind" do
      capture = fn prompt ->
        send(self(), {:prompt, prompt})
        {:ok, "debugging a flaky test"}
      end

      TaskKind.classify("the integration test fails 1 in 10 runs", capture)

      assert_received {:prompt, prompt}
      assert prompt =~ "the integration test fails 1 in 10 runs"
      assert prompt =~ "kind"
    end
  end

  describe "ex-task-kind > result" do
    test "returns {:ok, problem_kind}" do
      assert {:ok, "debugging a flaky test"} =
               TaskKind.classify("fix it", fn _ -> {:ok, "debugging a flaky test"} end)
    end

    test "propagates {:error, reason}" do
      assert {:error, :upstream} = TaskKind.classify("fix it", fn _ -> {:error, :upstream} end)
    end
  end

  describe "ex-task-kind > classify_schema/0" do
    test "declares a single required problem_kind string field" do
      schema = TaskKind.classify_schema()
      assert schema[:problem_kind][:type] == :string
      assert schema[:problem_kind][:required] == true
    end
  end
end
