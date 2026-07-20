defmodule Gralkor.Lens.Storage.InMemoryTest do
  use ExUnit.Case, async: false

  alias Gralkor.Lens
  alias Gralkor.Lens.Storage.InMemory
  alias Gralkor.Lens.Store

  setup do
    start_supervised!(InMemory)
    :ok
  end

  describe "when an operator-local or global Lens store adds episodes" do
    test "then each episode remains in insertion order within only its selected Lens destination" do
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
    test "then no more than that count is returned from the selected destination" do
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
end
