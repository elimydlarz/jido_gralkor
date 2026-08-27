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

  describe "when recall, capture, flush-and-await, memory addition, index rebuilding, or community building is called" do
    test "then the call is recorded with every argument it was given, so a consumer's exact request can be inspected afterwards" do
      InMemory.set_recall({:ok, "block"})
      InMemory.set_capture(:ok)
      InMemory.set_flush_and_await(:ok)
      InMemory.set_memory_add(:ok)
      InMemory.set_build_indices({:ok, %{status: "built"}})
      InMemory.set_build_communities({:ok, %{communities: 1, edges: 2}})

      InMemory.recall("g-1", "TestAgent", "s-1", "q?")
      InMemory.capture("s-1", "g-1", "TestAgent", "Eli", [Gralkor.Message.new("user", "hi")])
      InMemory.flush_and_await("s-1", 500)
      InMemory.memory_add("g-1", "fact", "source", :document)
      InMemory.build_indices()
      InMemory.build_communities("g-1")

      assert [["g-1", "TestAgent", "s-1", "q?"]] = InMemory.recalls()
      assert [["s-1", "g-1", "TestAgent", "Eli", _]] = InMemory.captures()
      assert [["s-1", 500]] = InMemory.flush_and_awaits()
      assert [["g-1", "fact", "source", :document]] = InMemory.adds()
      assert [[]] = InMemory.indices_builds()
      assert [["g-1"]] = InMemory.communities_builds()
    end
  end

  describe "if recall, capture, flush-and-await, memory addition, index rebuilding, or community building is called > while no response is configured for it" do
    test "then a not-configured error is returned rather than a fabricated success" do
      assert {:error, :not_configured} = InMemory.recall("g", "TestAgent", "s", "q")

      assert {:error, :not_configured} =
               InMemory.capture("s", "g", "TestAgent", "Eli", [
                 Gralkor.Message.new("user", "hi")
               ])

      assert {:error, :not_configured} = InMemory.flush_and_await("s", 500)
      assert {:error, :not_configured} = InMemory.memory_add("g", "fact", "source", :document)
      assert {:error, :not_configured} = InMemory.build_indices()
      assert {:error, :not_configured} = InMemory.build_communities("g")
    end
  end

  describe "if flush-and-await receives a timeout that is not a positive integer" do
    test "then an argument error is raised" do
      assert_raise ArgumentError, fn -> InMemory.flush_and_await("session", 0) end
    end

    test "and the error identifies the invalid timeout" do
      error = assert_raise ArgumentError, fn -> InMemory.flush_and_await("session", 0) end
      assert Exception.message(error) =~ "timeout_ms"
      assert Exception.message(error) =~ "0"
    end

    test "and no backend call is made" do
      assert_raise ArgumentError, fn -> InMemory.flush_and_await("session", -1) end
      assert InMemory.flush_and_awaits() == []
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
