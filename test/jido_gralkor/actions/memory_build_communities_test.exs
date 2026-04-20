defmodule JidoGralkor.Actions.MemoryBuildCommunitiesTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemoryBuildCommunities

  setup do
    InMemory.reset()
    :ok
  end

  test "the action description tells the LLM DO NOT CALL unless asked" do
    description =
      MemoryBuildCommunities.__action_metadata__()
      |> Map.get(:description)
      |> to_string()

    assert description =~ "DO NOT CALL"
  end

  test "passes sanitized group_id from context.agent_id to the client" do
    InMemory.set_build_communities({:ok, %{communities: 3, edges: 17}})

    assert {:ok, %{result: result}} =
             MemoryBuildCommunities.run(%{}, %{agent_id: "user-with-hyphens"})

    assert result =~ "3"
    assert result =~ "17"
    assert InMemory.communities_builds() == [["user_with_hyphens"]]
  end

  test "when the client returns {:error, reason}, the error is propagated" do
    InMemory.set_build_communities({:error, :boom})

    assert {:error, :boom} = MemoryBuildCommunities.run(%{}, %{agent_id: "01USER"})
  end
end
