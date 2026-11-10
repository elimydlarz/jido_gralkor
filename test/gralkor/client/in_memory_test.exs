defmodule Gralkor.Client.InMemoryTest do
  use ExUnit.Case, async: false

  @moduletag :integration

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
  defp configure_memory_add(response), do: InMemory.set_memory_add(response)
  defp configure_build_indices(response), do: InMemory.set_build_indices(response)
  defp configure_build_communities(response), do: InMemory.set_build_communities(response)

  describe "when recall, memory addition, index rebuilding, or community building is called" do
    @describetag :integration
    test "then the call is recorded with every argument it was given, so a consumer's exact request can be inspected afterwards" do
      InMemory.set_recall({:ok, "block"})
      InMemory.set_memory_add(:ok)
      InMemory.set_build_indices({:ok, %{status: "built"}})
      InMemory.set_build_communities({:ok, %{communities: 1, edges: 2}})

      InMemory.recall("g-1", "TestAgent", "s-1", "q?")

      InMemory.memory_add("g-1", "fact", "source", :document)
      InMemory.build_indices()
      InMemory.build_communities("g-1")

      assert [["g-1", "TestAgent", "s-1", "q?"]] = InMemory.recalls()

      assert [["g-1", "fact", "source", :document]] = InMemory.adds()
      assert [[]] = InMemory.indices_builds()
      assert [["g-1"]] = InMemory.communities_builds()
    end
  end

  describe "if recall, memory addition, index rebuilding, or community building is called > while no response is configured for it" do
    @describetag :integration
    test "then a not-configured error is returned rather than a fabricated success" do
      assert {:error, :not_configured} = InMemory.recall("g", "TestAgent", "s", "q")

      assert {:error, :not_configured} = InMemory.memory_add("g", "fact", "source", :document)
      assert {:error, :not_configured} = InMemory.build_indices()
      assert {:error, :not_configured} = InMemory.build_communities("g")
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
      original = Application.get_env(:jido_gralkor, :client)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:jido_gralkor, :client)
          value -> Application.put_env(:jido_gralkor, :client, value)
        end
      end)

      Application.put_env(:jido_gralkor, :client, __MODULE__)
      assert Gralkor.Client.impl() == __MODULE__
    end
  end

  run_contract(do: fn -> :ok end)
end
