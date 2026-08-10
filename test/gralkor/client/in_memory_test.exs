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

  run_contract(do: fn -> :ok end)

  describe "when any client operation is called" do
    test "then the call is recorded with every argument it was given, so a consumer's exact request can be inspected afterwards" do
      InMemory.set_recall({:ok, "block"})
      InMemory.recall("g-1", "TestAgent", "s-1", "q?")

      assert [["g-1", "TestAgent", "s-1", "q?"]] = InMemory.recalls()
    end
  end

  describe "if an operation is called > while no response is configured for it" do
    test "then a not-configured error is returned rather than a fabricated success" do
      assert {:error, :not_configured} = InMemory.recall("g", "TestAgent", "s", "q")
    end
  end

  describe "when the double is reset" do
    test "then every configured response is cleared" do
      InMemory.set_recall({:ok, "x"})
      InMemory.reset()
      assert {:error, :not_configured} = InMemory.recall("g", "TestAgent", "s", "q")
    end

    test "and every recorded call is cleared" do
      InMemory.set_recall({:ok, "x"})
      InMemory.recall("g", "TestAgent", "s", "q")
      InMemory.reset()

      assert [] = InMemory.recalls()
    end
  end

  describe "when the client implementation is resolved > while a client module is configured" do
    test "then that configured module is returned" do
      assert Application.get_env(:jido_gralkor, :client) == Gralkor.Client.InMemory
      assert Gralkor.Client.impl() == Gralkor.Client.InMemory
    end
  end
end
