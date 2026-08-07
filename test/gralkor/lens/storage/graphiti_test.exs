defmodule Gralkor.Lens.Storage.GraphitiTest do
  use ExUnit.Case, async: true

  alias Gralkor.Lens
  alias Gralkor.Lens.Replaceable
  alias Gralkor.Lens.Storage.Graphiti
  alias Gralkor.Lens.Store
  alias Gralkor.TestOntologies.Strict

  describe "when an operator-local Lens store adds an episode" do
    test "then Graphiti receives a deterministic group unique to the operator and Lens" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "observations",
          ontology: Strict,
          scope: :operator,
          ingestion: String
        }
      }

      test_pid = self()

      add_episode_fn = fn group_id, content, source_description, ontology, opts ->
        send(
          test_pid,
          {:graph_add, group_id, content, source_description, ontology, opts}
        )

        :ok
      end

      assert :ok =
               Graphiti.add_episode(
                 store,
                 "The launch window moved to Friday.",
                 "project update",
                 add_episode_fn: add_episode_fn
               )

      assert_receive {:graph_add, "lens_6f70657261746f722d6f6e65_6f62736572766174696f6e73", _, _,
                      _, _}
    end

    test "and changing either the operator or Lens produces a distinct group" do
      test_pid = self()

      add_episode_fn = fn group_id, _content, _source_description, _ontology, _opts ->
        send(test_pid, {:group_id, group_id})
        :ok
      end

      stores = [
        %Store{
          operator_id: "operator-one",
          lens: %Lens{name: "observations", ontology: Strict, scope: :operator, ingestion: String}
        },
        %Store{
          operator_id: "operator-two",
          lens: %Lens{name: "observations", ontology: Strict, scope: :operator, ingestion: String}
        },
        %Store{
          operator_id: "operator-one",
          lens: %Lens{name: "decisions", ontology: Strict, scope: :operator, ingestion: String}
        }
      ]

      group_ids =
        Enum.map(stores, fn store ->
          assert :ok =
                   Graphiti.add_episode(store, "content", "source",
                     add_episode_fn: add_episode_fn
                   )

          assert_receive {:group_id, group_id}
          group_id
        end)

      assert length(Enum.uniq(group_ids)) == 3
    end

    test "and the local group is distinct from the shared global group" do
      test_pid = self()

      add_episode_fn = fn group_id, _content, _source_description, _ontology, _opts ->
        send(test_pid, {:group_id, group_id})
        :ok
      end

      assert :ok =
               Graphiti.add_episode(local_store(), "content", "source",
                 add_episode_fn: add_episode_fn
               )

      assert_receive {:group_id, group_id}
      refute group_id == "global"
    end

    test "and the graph add receives the episode content, source description, and Lens ontology" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "observations",
          ontology: Strict,
          scope: :operator,
          ingestion: String
        }
      }

      test_pid = self()

      add_episode_fn = fn group_id, content, source_description, ontology, opts ->
        send(
          test_pid,
          {:graph_add, group_id, content, source_description, ontology, opts}
        )

        :ok
      end

      assert :ok =
               Graphiti.add_episode(
                 store,
                 "The launch window moved to Friday.",
                 "project update",
                 add_episode_fn: add_episode_fn
               )

      assert_receive {:graph_add, _, "The launch window moved to Friday.", "project update",
                      Strict, []}
    end

    test "and the graph add result is returned to the ingestion process" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "observations",
          ontology: Strict,
          scope: :operator,
          ingestion: String
        }
      }

      add_episode_fn = fn _group_id, _content, _source_description, _ontology, _opts ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.add_episode(store, "content", "source", add_episode_fn: add_episode_fn)
    end
  end

  describe "when an operator-local Lens store is searched" do
    test "then graph search receives the same deterministic operator-and-Lens group" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "observations",
          ontology: Strict,
          scope: :operator,
          ingestion: String
        }
      }

      test_pid = self()

      search_fn = fn group_id, query, max_results ->
        send(test_pid, {:graph_search, group_id, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} =
               Graphiti.search(store, "launch window", 7, search_fn: search_fn)

      assert_receive {:graph_search, "lens_6f70657261746f722d6f6e65_6f62736572766174696f6e73", _,
                      _}
    end

    test "and graph search receives the query and result limit" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "observations",
          ontology: Strict,
          scope: :operator,
          ingestion: String
        }
      }

      test_pid = self()

      search_fn = fn group_id, query, max_results ->
        send(test_pid, {:graph_search, group_id, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} = Graphiti.search(store, "launch window", 7, search_fn: search_fn)
      assert_receive {:graph_search, _, "launch window", 7}
    end

    test "and the graph search result is returned to the caller" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "observations",
          ontology: Strict,
          scope: :operator,
          ingestion: String
        }
      }

      search_fn = fn _group_id, _query, _max_results ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.search(store, "launch window", 7, search_fn: search_fn)
    end
  end

  describe "when the implicit `default` Lens is added to or searched" do
    test "then graph operations use the operator's existing sanitised group id" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "default",
          ontology: Strict,
          scope: :operator,
          ingestion: Gralkor.Lens.Ingestion.Store
        }
      }

      test_pid = self()

      add_episode_fn = fn group_id, _, _, _, _ ->
        send(test_pid, {:graph_add, group_id})
        :ok
      end

      search_fn = fn group_id, _, _ ->
        send(test_pid, {:graph_search, group_id})
        {:ok, []}
      end

      assert :ok =
               Graphiti.add_episode(store, "content", "source", add_episode_fn: add_episode_fn)

      assert {:ok, []} = Graphiti.search(store, "content", 5, search_fn: search_fn)
      assert_receive {:graph_add, "operator_one"}
      assert_receive {:graph_search, "operator_one"}
    end
  end

  describe "when a global Lens store adds an episode" do
    test "then graph add receives the fixed global group" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "published-observations",
          ontology: Strict,
          scope: :global,
          ingestion: String
        }
      }

      test_pid = self()

      add_episode_fn = fn group_id, content, source_description, ontology, opts ->
        send(
          test_pid,
          {:graph_add, group_id, content, source_description, ontology, opts}
        )

        :ok
      end

      assert :ok =
               Graphiti.add_episode(store, "public fact", "publication",
                 add_episode_fn: add_episode_fn
               )

      assert_receive {:graph_add, "global", _, _, _, _}
    end

    test "and the episode source description identifies the originating Lens in the same graph add" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "published-observations",
          ontology: Strict,
          scope: :global,
          ingestion: String
        }
      }

      test_pid = self()

      add_episode_fn = fn group_id, content, source_description, ontology, opts ->
        send(
          test_pid,
          {:graph_add, group_id, content, source_description, ontology, opts}
        )

        :ok
      end

      assert :ok =
               Graphiti.add_episode(store, "public fact", "publication",
                 add_episode_fn: add_episode_fn
               )

      assert_receive {:graph_add, "global", "public fact", "publication", Strict,
                      [lens: "published-observations"]}
    end
  end

  describe "when the reserved `global` Lens is searched" do
    test "then graph search receives the fixed global group" do
      store = %Store{operator_id: "operator-one", lens: :global}
      test_pid = self()

      search_fn = fn group_id, query, max_results ->
        send(test_pid, {:graph_search, group_id, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} = Graphiti.search(store, "launch window", 7, search_fn: search_fn)
      assert_receive {:graph_search, "global", "launch window", 7}
    end

    test "and no originating-Lens filter is supplied" do
      store = %Store{operator_id: "operator-one", lens: :global}
      test_pid = self()

      search_fn = fn group_id, query, max_results ->
        send(test_pid, {:graph_search, group_id, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} = Graphiti.search(store, "launch window", 7, search_fn: search_fn)
      assert_receive {:graph_search, "global", "launch window", 7}
    end
  end

  describe "when a store bound to a global Lens is searched by its ingestion process" do
    test "then graph search receives the fixed unfiltered global group" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "generalisations",
          ontology: Strict,
          scope: :global,
          ingestion: Gralkor.Lens.Ingestion.Generalise
        }
      }

      test_pid = self()

      search_fn = fn group_id, query, max_results ->
        send(test_pid, {:graph_search, group_id, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} = Graphiti.search(store, "launch window", 7, search_fn: search_fn)
      assert_receive {:graph_search, "global", "launch window", 7}
    end
  end

  describe "when an operator-local replaceable Lens store replaces a complete graph" do
    test "then graph replacement receives the same deterministic operator-and-Lens group used by existing Lens operations" do
      store = replaceable_store(:operator)
      graph = property_graph()
      data = graph.data
      test_pid = self()

      replace_graph_fn = fn group_id, _lens_name, _format, _data ->
        send(test_pid, {:graph_replaced, group_id})
        :ok
      end

      assert :ok = Graphiti.replace_graph(store, graph, replace_graph_fn: replace_graph_fn)

      assert_receive {:graph_replaced,
                      "lens_6f70657261746f722d6f6e65_73797374656d73"}
    end

    test "and graph replacement receives the selected Lens name, configured graph format, and supplied graph data" do
      store = replaceable_store(:operator)
      graph = property_graph()
      test_pid = self()

      replace_graph_fn = fn group_id, lens_name, format, data ->
        send(test_pid, {:graph_replaced, group_id, lens_name, format, data})
        :ok
      end

      assert :ok = Graphiti.replace_graph(store, graph, replace_graph_fn: replace_graph_fn)

      assert_receive {:graph_replaced, _, "systems", :property_graph, ^data}
    end

    test "and the graph replacement result is returned to the caller" do
      replace_graph_fn = fn _group_id, _lens_name, _format, _data ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.replace_graph(replaceable_store(:operator), property_graph(),
                 replace_graph_fn: replace_graph_fn
               )
    end
  end

  describe "when a global replaceable Lens store replaces a complete graph" do
    test "then graph replacement receives the fixed global group" do
      test_pid = self()

      replace_graph_fn = fn group_id, _lens_name, _format, _data ->
        send(test_pid, {:graph_replaced, group_id})
        :ok
      end

      assert :ok =
               Graphiti.replace_graph(replaceable_store(:global), property_graph(),
                 replace_graph_fn: replace_graph_fn
               )

      assert_receive {:graph_replaced, "global"}
    end

    test "and graph replacement receives the selected Lens name, configured graph format, and supplied graph data" do
      graph = property_graph()
      data = graph.data
      test_pid = self()

      replace_graph_fn = fn group_id, lens_name, format, data ->
        send(test_pid, {:graph_replaced, group_id, lens_name, format, data})
        :ok
      end

      assert :ok =
               Graphiti.replace_graph(replaceable_store(:global), graph,
                 replace_graph_fn: replace_graph_fn
               )

      assert_receive {:graph_replaced, "global", "systems", :property_graph, ^data}
    end

    test "and the graph replacement result is returned to the caller" do
      replace_graph_fn = fn _group_id, _lens_name, _format, _data ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.replace_graph(replaceable_store(:global), property_graph(),
                 replace_graph_fn: replace_graph_fn
               )
    end
  end

  defp local_store do
    %Store{
      operator_id: "operator-one",
      lens: %Lens{
        name: "observations",
        ontology: Strict,
        scope: :operator,
        ingestion: String
      }
    }
  end

  defp replaceable_store(scope) do
    %Store{
      operator_id: "operator-one",
      lens: %Replaceable{name: "systems", scope: scope, graph_format: :property_graph}
    }
  end

  defp property_graph do
    %Gralkor.Graph{
      format: :property_graph,
      data: %{
        nodes: [%{id: "system", labels: ["System"], properties: %{name: "payments"}}],
        relationships: []
      }
    }
  end
end
