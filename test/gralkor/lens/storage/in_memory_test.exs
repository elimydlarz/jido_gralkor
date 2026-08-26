defmodule Gralkor.Lens.Storage.InMemoryTest do
  use ExUnit.Case, async: false

  alias Gralkor.Lens
  alias Gralkor.Destination
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

  describe "when a Lens store adds episodes to the `operator`, `global`, or an application Destination" do
    test "then each episode remains in insertion order within only its Destination" do
      operator = operator_store("operator-one")
      decisions = application_store("operator-one", "decisions")
      global = global_store("published-observations")

      assert :ok = Store.add(operator, "first observation", "test")
      assert :ok = Store.add(decisions, "one decision", "test")
      assert :ok = Store.add(operator, "second observation", "test")
      assert :ok = Store.add(global, "public observation", "test")

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

      assert :ok = Store.add(observations, "private", "test")
      assert :ok = Store.add(published, "public", "test")
      assert :ok = Store.add(generalisations, "durable", "test")

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

  describe "when a replaceable Lens store replaces a complete graph" do
    test "then the graph is stored within only its resolved Destination" do
      local = replaceable_store("operator-one", "systems", :operator)
      global = replaceable_store("operator-one", "catalogue", :global)
      graph = %Gralkor.Graph{format: :property_graph, data: graph_data("system")}

      assert :ok = Store.replace_graph(local, graph)
      assert :ok = Store.replace_graph(global, graph)

      assert %{nodes: [%{id: "system"}]} = InMemory.graph(key(local))
      assert %{nodes: [%{id: "system"}]} = InMemory.graph(key(global))

      assert InMemory.graph(key(replaceable_store("operator-two", "systems", :operator))) == %{
               nodes: [],
               relationships: []
             }
    end

    test "and every supplied node and relationship retains each non-reserved graph value" do
      store = replaceable_store("operator-one", "systems", :operator)

      graph = %Gralkor.Graph{
        format: :property_graph,
        data: %{
          nodes: [
            %{
              id: "source",
              labels: ["System", "Critical"],
              properties: %{name: "payments", priority: 1}
            },
            %{id: "target", labels: ["System"], properties: %{name: "ledger"}}
          ],
          relationships: [
            %{
              from: "source",
              to: "target",
              type: "DEPENDS_ON",
              properties: %{protocol: "events"}
            }
          ]
        }
      }

      assert :ok = Store.replace_graph(store, graph)

      assert %{
               nodes: [
                 %{
                   id: "source",
                   labels: ["System", "Critical"],
                   properties: %{name: "payments", priority: 1, _gralkor_lens: "systems"}
                 },
                 %{
                   id: "target",
                   labels: ["System"],
                   properties: %{name: "ledger", _gralkor_lens: "systems"}
                 }
               ],
               relationships: [
                 %{
                   from: "source",
                   to: "target",
                   type: "DEPENDS_ON",
                   properties: %{protocol: "events", _gralkor_lens: "systems"}
                 }
               ]
             } = InMemory.graph(key(store))
    end

    test "and every supplied node and relationship records the replacing Lens as its owner" do
      store = replaceable_store("operator-one", "systems", :operator)

      graph = %Gralkor.Graph{
        format: :property_graph,
        data: %{
          nodes: [
            %{id: "source", labels: ["System"], properties: %{}},
            %{id: "target", labels: ["System"], properties: %{}}
          ],
          relationships: [
            %{from: "source", to: "target", type: "DEPENDS_ON", properties: %{}}
          ]
        }
      }

      assert :ok = Store.replace_graph(store, graph)

      assert %{
               nodes: [
                 %{properties: %{_gralkor_lens: "systems"}},
                 %{properties: %{_gralkor_lens: "systems"}}
               ],
               relationships: [%{properties: %{_gralkor_lens: "systems"}}]
             } = InMemory.graph(key(store))
    end

    test "and graph content previously owned by the replacing Lens at that destination is removed" do
      systems = replaceable_store("operator-one", "systems", :global)

      first = %Gralkor.Graph{
        format: :property_graph,
        data: %{
          nodes: [
            %{id: "old-source", labels: ["System"], properties: %{}},
            %{id: "old-target", labels: ["System"], properties: %{}}
          ],
          relationships: [
            %{from: "old-source", to: "old-target", type: "DEPENDS_ON", properties: %{}}
          ]
        }
      }

      assert :ok = Store.replace_graph(systems, first)

      assert :ok =
               Store.replace_graph(
                 systems,
                 %Gralkor.Graph{format: :property_graph, data: graph_data("current")}
               )

      assert %{nodes: [%{id: "current"}], relationships: []} = InMemory.graph(key(systems))
    end

    test "and graph content owned by another Lens at that destination remains unchanged" do
      catalogue = replaceable_store("operator-one", "catalogue", :global)
      systems = replaceable_store("operator-one", "systems", :global)

      assert :ok =
               Store.replace_graph(
                 catalogue,
                 %Gralkor.Graph{format: :property_graph, data: graph_data("catalogue")}
               )

      assert :ok =
               Store.replace_graph(
                 systems,
                 %Gralkor.Graph{format: :property_graph, data: graph_data("systems")}
               )

      assert %{nodes: nodes} = InMemory.graph(key(systems))

      assert Enum.map(nodes, &{&1.id, &1.properties._gralkor_lens}) == [
               {"catalogue", "catalogue"},
               {"systems", "systems"}
             ]
    end

    test "and graph content without a Lens owner at that destination remains unchanged" do
      unowned_graph = %{
        nodes: [%{id: "unowned", labels: ["External"], properties: %{source: "manual"}}],
        relationships: []
      }

      systems = replaceable_store("operator-one", "systems", :global)
      :sys.replace_state(InMemory, &Map.put(&1, {:graph, key(systems)}, unowned_graph))

      assert :ok =
               Store.replace_graph(
                 systems,
                 %Gralkor.Graph{format: :property_graph, data: graph_data("systems")}
               )

      assert %{nodes: [unowned, owned]} = InMemory.graph(key(systems))
      assert unowned == %{id: "unowned", labels: ["External"], properties: %{source: "manual"}}
      assert owned.id == "systems"
    end

    test "and information saved through Reflections at that destination remains unchanged" do
      systems = replaceable_store("operator-one", "systems", :global)

      reflection_information = %{
        nodes: [
          %{id: "learning", labels: ["Learning"], properties: %{reflection: "erl"}}
        ],
        relationships: []
      }

      :sys.replace_state(
        InMemory,
        &Map.put(&1, {:graph, key(systems)}, reflection_information)
      )

      assert :ok =
               Store.replace_graph(
                 systems,
                 %Gralkor.Graph{format: :property_graph, data: graph_data("systems")}
               )

      assert %{nodes: [learning, owned]} = InMemory.graph(key(systems))
      assert learning.properties == %{reflection: "erl"}
      assert owned.properties._gralkor_lens == "systems"
    end
  end

  describe "where a replaceable Lens store supplies an empty complete graph" do
    test "then graph content previously owned by the replacing Lens at that destination is removed" do
      systems = replaceable_store("operator-one", "systems", :global)

      assert :ok =
               Store.replace_graph(
                 systems,
                 %Gralkor.Graph{format: :property_graph, data: graph_data("old")}
               )

      assert :ok = Store.replace_graph(systems, empty_graph())
      assert InMemory.graph(key(systems)) == %{nodes: [], relationships: []}
    end

    test "and no replacement graph content is stored" do
      systems = replaceable_store("operator-one", "systems", :global)

      assert :ok = Store.replace_graph(systems, empty_graph())
      assert InMemory.graph(key(systems)) == %{nodes: [], relationships: []}
    end
  end

  describe "when a replaceable Lens store replaces its complete graph more than once" do
    test "then only the most recently supplied graph remains owned by that Lens at the resolved destination" do
      systems = replaceable_store("operator-one", "systems", :global)

      for id <- ["first", "second", "current"] do
        assert :ok =
                 Store.replace_graph(
                   systems,
                   %Gralkor.Graph{format: :property_graph, data: graph_data(id)}
                 )
      end

      assert %{nodes: [%{id: "current"}], relationships: []} = InMemory.graph(key(systems))
    end
  end

  describe "when a replaceable Lens store is searched" do
    test "then search reads from its resolved Destination" do
      local = replaceable_store("operator-one", "systems", :operator)
      global = replaceable_store("operator-one", "systems", :global)

      assert {:ok, []} = Store.search(local, "settlement", 5)
      assert {:ok, []} = Store.search(global, "settlement", 5)
    end
  end

  defp operator_store(operator_id) do
    %Store{
      operator_id: operator_id,
      lens: %Lens{
        name: "operator",
        destination: destination("operator"),
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

  defp replaceable_store(operator_id, name, scope) do
    %Store{
      operator_id: operator_id,
      lens: %Replaceable{
        name: name,
        destination: destination(Atom.to_string(scope)),
        graph_format: :property_graph
      }
    }
  end

  defp destination(name), do: %Destination{name: name}

  defp key(%Store{operator_id: operator_id, lens: %{destination: destination}}),
    do: Destination.graph_id(destination, operator_id)

  defp graph_data(id) do
    %{nodes: [%{id: id, labels: ["System"], properties: %{name: id}}], relationships: []}
  end

  defp empty_graph do
    %Gralkor.Graph{format: :property_graph, data: %{nodes: [], relationships: []}}
  end
end
