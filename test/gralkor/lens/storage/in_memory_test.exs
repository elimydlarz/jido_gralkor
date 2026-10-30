defmodule Gralkor.Lens.Storage.InMemoryTest do
  use ExUnit.Case, async: false

  alias Gralkor.Lens
  alias Gralkor.Destination
  alias Gralkor.Lens.Storage.InMemory
  alias Gralkor.Lens.Store

  setup do
    start_supervised!(InMemory)
    :ok
  end

  describe "when a Lens store adds episodes to the `personal`, `global`, or an application Destination" do
    test "then each episode remains in insertion order within only its Destination" do
      operator = operator_store("operator-one")
      decisions = application_store("operator-one", "decisions")
      global = global_store("published-observations")

      assert :ok = InMemory.add_episode(operator, "first observation", "test")
      assert :ok = InMemory.add_episode(decisions, "one decision", "test")
      assert :ok = InMemory.add_episode(operator, "second observation", "test")
      assert :ok = InMemory.add_episode(global, "public observation", "test")

      assert Enum.map(InMemory.episodes(key(operator)), & &1.content) ==
               ["first observation", "second observation"]

      assert Enum.map(InMemory.episodes(key(decisions)), & &1.content) ==
               ["one decision"]

      assert Enum.map(InMemory.episodes(key(global)), & &1.content) == ["public observation"]
      assert InMemory.episodes(key(operator_store("operator-two"))) == []
    end

    test "and every stored episode retains its originating Lens" do
      observations = application_store("operator-one", "observations")
      published = global_store("published-observations")
      generalisations = global_store("generalisations")

      assert :ok = InMemory.add_episode(observations, "private", "test")
      assert :ok = InMemory.add_episode(published, "public", "test")
      assert :ok = InMemory.add_episode(generalisations, "durable", "test")

      assert [%{lens: "observations"}] =
               InMemory.episodes(key(observations))

      assert [%{lens: "published-observations"}, %{lens: "generalisations"}] =
               InMemory.episodes(key(published))
    end
  end

  describe "when a Lens store is searched with a maximum result count" do
    test "then no more than that count is returned from the selected Destination" do
      observations = application_store("operator-one", "observations")

      Enum.each(["first", "second", "third"], fn content ->
        assert :ok = InMemory.add_episode(observations, content, "test")
      end)

      assert {:ok, ["first", "second"]} = InMemory.search(observations, "anything", 2)
    end

    test "and the retained insertion order is preserved" do
      global = global_store("published-observations")

      Enum.each(["first", "second", "third"], fn content ->
        assert :ok = InMemory.add_episode(global, content, "test")
      end)

      assert {:ok, ["first", "second", "third"]} = InMemory.search(global, "anything", 3)
    end
  end

  defp operator_store(operator_id) do
    %Store{
      operator_id: operator_id,
      lens: %Lens{
        name: "personal-chat",
        destination: destination("personal"),
        ontology: Gralkor.DefaultOntology,
        ingestion: String
      }
    }
  end

  defp application_store(operator_id, name) do
    %Store{
      operator_id: operator_id,
      lens: %Lens{
        name: name,
        destination: destination(name),
        ontology: Gralkor.DefaultOntology,
        ingestion: String
      }
    }
  end

  defp global_store(name) do
    %Store{
      operator_id: "operator-one",
      lens: %Lens{
        name: name,
        destination: destination("global"),
        ontology: Gralkor.DefaultOntology,
        ingestion: String
      }
    }
  end

  defp destination(name), do: %Destination{name: name}

  defp key(%Store{operator_id: operator_id, lens: %{destination: destination}}),
    do: Destination.graph_id(destination, operator_id)
end
end
