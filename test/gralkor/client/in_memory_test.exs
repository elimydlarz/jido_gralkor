defmodule Gralkor.Client.InMemoryTest do
  use ExUnit.Case, async: false

  alias Gralkor.Client.InMemory

  import Gralkor.ClientContract

  setup do
    case Process.whereis(InMemory) do
      nil -> {:ok, _pid} = InMemory.start_link([])
      _ -> InMemory.reset()
    end

    :ok
  end

  defp client, do: InMemory

  defp configure_recall(response), do: InMemory.set_recall(response)
  defp configure_capture(response), do: InMemory.set_capture(response)
  defp configure_flush(response), do: InMemory.set_flush(response)
  defp configure_flush_and_await(response), do: InMemory.set_flush_and_await(response)
  defp configure_memory_add(response), do: InMemory.set_memory_add(response)
  defp configure_build_indices(response), do: InMemory.set_build_indices(response)
  defp configure_build_communities(response), do: InMemory.set_build_communities(response)

  run_contract do: fn -> :ok end

  describe "ex-client-in-memory > when an operation is called" do
    test "the call is recorded with its arguments (including agent_name) for later inspection" do
      InMemory.set_recall({:ok, "block"})
      InMemory.recall("g-1", "TestAgent", "s-1", "q?")

      assert [["g-1", "TestAgent", "s-1", "q?"]] = InMemory.recalls()
    end
  end

  describe "ex-client-in-memory > if no response is configured for an operation" do
    test "{:error, :not_configured} is returned" do
      assert {:error, :not_configured} = InMemory.recall("g", "TestAgent", "s", "q")
    end
  end

  describe "ex-client-in-memory > when reset/0 is called" do
    test "configured responses and recorded calls are cleared" do
      InMemory.set_recall({:ok, "x"})
      InMemory.recall("g", "TestAgent", "s", "q")
      InMemory.reset()

      assert [] = InMemory.recalls()
      assert {:error, :not_configured} = InMemory.recall("g", "TestAgent", "s", "q")
    end
  end
end
