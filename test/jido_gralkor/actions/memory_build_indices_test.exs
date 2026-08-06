defmodule JidoGralkor.Actions.MemoryBuildIndicesTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemoryBuildIndices

  setup do
    InMemory.reset()
    :ok
  end

  describe "when a model reads the build-indices tool's description" do
    test "then it is told not to call the tool unless the operator explicitly asks" do
    description =
      MemoryBuildIndices.__action_metadata__()
      |> Map.get(:description)
      |> to_string()

    assert description =~ "DO NOT CALL"
    end
  end

  describe "when the build-indices tool runs" do
    test "then the backend is asked to build indices once, unscoped to any operator" do
      InMemory.set_build_indices({:ok, %{status: "stored"}})

      assert {:ok, %{result: _result}} = MemoryBuildIndices.run(%{}, %{agent_id: "01USER"})

      assert InMemory.indices_builds() == [[]]
    end
  end

  describe "when the build-indices tool runs > while the backend reports a status" do
    test "then the action result reports success carrying that status" do
      InMemory.set_build_indices({:ok, %{status: "stored"}})

      assert {:ok, %{result: result}} = MemoryBuildIndices.run(%{}, %{agent_id: "01USER"})

      assert result =~ "stored"
    end
  end

  describe "when the build-indices tool runs > if the backend fails" do
    test "then the failure reason is returned to the caller unchanged" do
      InMemory.set_build_indices({:error, :boom})

      assert {:error, :boom} = MemoryBuildIndices.run(%{}, %{agent_id: "01USER"})
    end
  end
end
