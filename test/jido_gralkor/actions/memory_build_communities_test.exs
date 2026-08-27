defmodule JidoGralkor.Actions.MemoryBuildCommunitiesTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemoryBuildCommunities

  setup do
    InMemory.reset()
    :ok
  end

  describe "when a model reads the build-communities tool's description" do
    test "then it is told not to call the tool unless the operator explicitly asks" do
      description =
        MemoryBuildCommunities.__action_metadata__()
        |> Map.get(:description)
        |> to_string()

      assert description =~ "DO NOT CALL"
    end
  end

  describe "when the build-communities tool runs" do
    test "then the graph named `operator/<operator id>` is passed to the backend" do
      InMemory.set_build_communities({:ok, %{communities: 3, edges: 17}})

      assert {:ok, %{result: _result}} =
               MemoryBuildCommunities.run(%{}, %{agent_id: "user-with-hyphens"})

      assert InMemory.communities_builds() == [["operator/user-with-hyphens"]]
    end
  end

  describe "when the build-communities tool runs > while the backend reports how many communities and edges it built" do
    test "then the action result reports both counts" do
      InMemory.set_build_communities({:ok, %{communities: 3, edges: 17}})

      assert {:ok, %{result: result}} =
               MemoryBuildCommunities.run(%{}, %{agent_id: "user-with-hyphens"})

      assert result =~ "3"
      assert result =~ "17"
    end
  end

  describe "when the build-communities tool runs > if the backend fails" do
    test "then the failure reason is returned to the caller unchanged" do
      InMemory.set_build_communities({:error, :boom})

      assert {:error, :boom} = MemoryBuildCommunities.run(%{}, %{agent_id: "01USER"})
    end
  end
end
