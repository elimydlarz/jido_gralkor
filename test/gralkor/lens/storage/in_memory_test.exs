defmodule Gralkor.Lens.Storage.InMemoryTest do
  use ExUnit.Case, async: false

  alias Gralkor.Lens
  alias Gralkor.Lens.Replaceable
  alias Gralkor.Lens.Storage.InMemory
  alias Gralkor.Lens.Store

  setup do
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)
    Application.put_env(:jido_gralkor, :lens_storage, InMemory)
    start_supervised!(InMemory)

    on_exit(fn ->
      if previous_storage do
        Application.put_env(:jido_gralkor, :lens_storage, previous_storage)
      else
        Application.delete_env(:jido_gralkor, :lens_storage)
      end
    end)

    :ok
  end

  describe "when an operator-local or global Lens store adds episodes" do
    test "then each episode remains in insertion order within only its selected Lens group" do
      observations = local_store("operator-one", "observations")
      decisions = local_store("operator-one", "decisions")
      global = global_store("published-observations")

      assert :ok = Store.add(observations, "first observation", "test")
      assert :ok = Store.add(decisions, "one decision", "test")
      assert :ok = Store.add(observations, "second observation", "test")
      assert :ok = Store.add(global, "public observation", "test")

      assert Enum.map(InMemory.episodes({"operator-one", "observations"}), & &1.content) ==
               ["first observation", "second observation"]

      assert Enum.map(InMemory.episodes({"operator-one", "decisions"}), & &1.content) ==
               ["one decision"]

      assert Enum.map(InMemory.episodes(:global), & &1.content) == ["public observation"]
      assert InMemory.episodes({"operator-two", "observations"}) == []
    end

    test "and every stored episode retains its originating Lens" do
      observations = local_store("operator-one", "observations")
      published = global_store("published-observations")
      generalisations = global_store("generalisations")

      assert :ok = Store.add(observations, "private", "test")
      assert :ok = Store.add(published, "public", "test")
      assert :ok = Store.add(generalisations, "durable", "test")

      assert [%{lens: "observations"}] =
               InMemory.episodes({"operator-one", "observations"})

      assert [%{lens: "published-observations"}, %{lens: "generalisations"}] =
               InMemory.episodes(:global)
    end
  end

  describe "when an operator-local or global Lens store is searched with a maximum result count" do
    test "then no more than that count is returned from the selected group" do
      observations = local_store("operator-one", "observations")

      Enum.each(["first", "second", "third"], fn content ->
        assert :ok = Store.add(observations, content, "test")
      end)

      assert {:ok, ["first", "second"]} = Store.search(observations, "anything", 2)
    end

    test "and the retained insertion order is preserved" do
      global = global_store("published-observations")

      Enum.each(["first", "second", "third"], fn content ->
        assert :ok = Store.add(global, content, "test")
      end)

      assert {:ok, ["first", "second", "third"]} = Store.search(global, "anything", 3)
    end
  end

  describe "when an operator-local or global replaceable Lens store replaces a complete graph" do
    test "then the graph is stored within only the destination resolved from the Lens scope" do
      local = replaceable_store("operator-one", "systems", :operator)
      global = replaceable_store("operator-one", "catalogue", :global)
      graph = %Gralkor.Graph{format: :property_graph, data: graph_data("system")}

      assert :ok = Store.replace_graph(local, graph)
      assert :ok = Store.replace_graph(global, graph)

      assert %{nodes: [%{id: "system"}]} = InMemory.graph({"operator-one", "systems"})
      assert %{nodes: [%{id: "system"}]} = InMemory.graph(:global)
      assert InMemory.graph({"operator-two", "systems"}) == %{nodes: [], relationships: []}
    end
  end

  defp local_store(operator_id, name) do
    %Store{
      operator_id: operator_id,
      lens: %Lens{name: name, ontology: nil, scope: :operator, ingestion: String}
    }
  end

  defp global_store(name) do
    %Store{
      operator_id: "operator-one",
      lens: %Lens{name: name, ontology: nil, scope: :global, ingestion: String}
    }
  end

  defp replaceable_store(operator_id, name, scope) do
    %Store{
      operator_id: operator_id,
      lens: %Replaceable{name: name, scope: scope, graph_format: :property_graph}
    }
  end

  defp graph_data(id) do
    %{nodes: [%{id: id, labels: ["System"], properties: %{name: id}}], relationships: []}
  end
end
