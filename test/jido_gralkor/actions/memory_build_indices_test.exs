defmodule JidoGralkor.Actions.MemoryBuildIndicesTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.InMemory
  alias JidoGralkor.Actions.MemoryBuildIndices

  setup do
    InMemory.reset()
    :ok
  end

  test "the action description tells the LLM DO NOT CALL unless asked" do
    description =
      MemoryBuildIndices.__action_metadata__()
      |> Map.get(:description)
      |> to_string()

    assert description =~ "DO NOT CALL"
  end

  test "when the client returns {:ok, %{status: status}}, the action result reports success" do
    InMemory.set_build_indices({:ok, %{status: "stored"}})

    assert {:ok, %{result: result}} = MemoryBuildIndices.run(%{}, %{agent_id: "01USER"})

    assert result =~ "stored"
    assert InMemory.indices_builds() == [[]]
  end

  test "when the client returns {:error, reason}, the error is propagated" do
    InMemory.set_build_indices({:error, :boom})

    assert {:error, :boom} = MemoryBuildIndices.run(%{}, %{agent_id: "01USER"})
  end
end
