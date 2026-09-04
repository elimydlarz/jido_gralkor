defmodule Gralkor.Lens.Storage.GraphitiTest do
  use ExUnit.Case, async: true

  alias Gralkor.Lens
  alias Gralkor.Destination
  alias Gralkor.Lens.Replaceable
  alias Gralkor.Lens.Storage.Graphiti
  alias Gralkor.Lens.Store
  alias Gralkor.TestOntologies.Strict

  describe "when a Lens store adds an episode to the `operator` Destination" do
    test "then Graphiti receives the group named `operator/<operator id>`" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "operator")
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

      assert_receive {:graph_add, "operator/operator-one", _, _, _, _}
    end

    test "and changing the operator produces a distinct group" do
      test_pid = self()

      add_episode_fn = fn group_id, _content, _source_description, _ontology, _opts ->
        send(test_pid, {:group_id, group_id})
        :ok
      end

      stores = [
        %Store{
          operator_id: "operator-one",
          lens: lens("observations", "operator")
        },
        %Store{
          operator_id: "operator-two",
          lens: lens("observations", "operator")
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

      assert length(Enum.uniq(group_ids)) == 2
    end

    test "and the graph add receives the episode content, source description, and Lens ontology" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "operator")
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
                      Strict, [lens: "observations"]}
    end

    test "and the graph add result is returned to the ingestion process" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "operator")
      }

      add_episode_fn = fn _group_id, _content, _source_description, _ontology, _opts ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.add_episode(store, "content", "source", add_episode_fn: add_episode_fn)
    end
  end

  describe "when a Lens store adds an episode carrying a source kind" do
    test "then Graphiti receives that source kind unchanged" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "operator"),
        source_kind: :structured_record
      }

      test_pid = self()

      add_episode_fn = fn _group_id, _content, _source_description, _ontology, opts ->
        send(test_pid, {:graph_opts, opts})
        :ok
      end

      assert :ok =
               Graphiti.add_episode(store, "content", "source", add_episode_fn: add_episode_fn)

      assert_receive {:graph_opts, opts}
      assert opts[:source_kind] == :structured_record
    end
  end

  describe "if a Lens store receives an unsupported addition or replacement option" do
    test "then an `ArgumentError` is raised" do
      Enum.each(unsupported_operations(self()), fn operation ->
        assert_raise ArgumentError, operation
      end)
    end

    test "and the error identifies the unsupported option" do
      Enum.each(unsupported_operations(self()), fn operation ->
        error = assert_raise ArgumentError, operation
        assert Exception.message(error) =~ "unsupported_option"
      end)
    end

    test "and no Graphiti operation begins" do
      Enum.each(unsupported_operations(self()), fn operation ->
        assert_raise ArgumentError, operation
      end)

      refute_receive :graphiti_operation_began
    end
  end

  describe "when a Lens store using the `operator` Destination is searched" do
    test "then graph search receives the same resolved group" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "operator")
      }

      test_pid = self()

      search_fn = fn group_id, query, max_results ->
        send(test_pid, {:graph_search, group_id, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} =
               Graphiti.search(store, "launch window", 7, search_fn: search_fn)

      assert_receive {:graph_search, "operator/operator-one", _, _}
    end

    test "and graph search receives the query and result limit" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "operator")
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
        lens: lens("observations", "operator")
      }

      search_fn = fn _group_id, _query, _max_results ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.search(store, "launch window", 7, search_fn: search_fn)
    end
  end

  describe "when the implicit `operator` Lens's packaged Destination is added to or searched" do
    test "then graph operations use the group named `operator/<operator id>`" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "operator",
          destination: destination("operator"),
          ontology: Strict,
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
      assert_receive {:graph_add, "operator/operator-one"}
      assert_receive {:graph_search, "operator/operator-one"}
    end
  end

  describe "when a Lens store adds an episode to the `global` Destination" do
    test "then graph add receives the group named `global` for every operator" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("published-observations", "global")
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
  end

  describe "when a Lens store adds an episode to an application Destination" do
    test "then graph add receives the group named for that Destination for every operator" do
      store = %Store{operator_id: "operator-one", lens: lens("observations", "observations")}
      test_pid = self()

      add_episode_fn = fn group_id, _, _, _, _ ->
        send(test_pid, {:graph_add, group_id})
        :ok
      end

      assert :ok = Graphiti.add_episode(store, "fact", "source", add_episode_fn: add_episode_fn)
      assert_receive {:graph_add, "observations"}
    end
  end

  describe "when a replaceable Lens store using the `operator` Destination replaces a complete graph" do
    test "then graph replacement receives the same resolved group used by existing Lens operations" do
      store = replaceable_store(:operator)
      graph = property_graph()
      test_pid = self()

      replace_graph_fn = fn group_id, _lens_name, _data ->
        send(test_pid, {:graph_replaced, group_id})
        :ok
      end

      assert :ok = Graphiti.replace_graph(store, graph, replace_graph_fn: replace_graph_fn)

      assert_receive {:graph_replaced, "operator/operator-one"}
    end

    test "and graph replacement receives the selected Lens name and supplied nodes and relationships" do
      store = replaceable_store(:operator)
      graph = property_graph()
      data = Map.from_struct(graph)
      test_pid = self()

      replace_graph_fn = fn group_id, lens_name, data ->
        send(test_pid, {:graph_replaced, group_id, lens_name, data})
        :ok
      end

      assert :ok = Graphiti.replace_graph(store, graph, replace_graph_fn: replace_graph_fn)

      assert_receive {:graph_replaced, _, "systems", ^data}
    end

    test "and the graph replacement result is returned to the caller" do
      replace_graph_fn = fn _group_id, _lens_name, _data ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.replace_graph(replaceable_store(:operator), property_graph(),
                 replace_graph_fn: replace_graph_fn
               )
    end
  end

  describe "when a replaceable Lens store using the `global` Destination replaces a complete graph" do
    test "then graph replacement receives the group named `global` for every operator" do
      test_pid = self()

      replace_graph_fn = fn group_id, _lens_name, _data ->
        send(test_pid, {:graph_replaced, group_id})
        :ok
      end

      assert :ok =
               Graphiti.replace_graph(replaceable_store(:global), property_graph(),
                 replace_graph_fn: replace_graph_fn
               )

      assert_receive {:graph_replaced, "global"}
    end

    test "and graph replacement receives the selected Lens name and supplied nodes and relationships" do
      graph = property_graph()
      data = Map.from_struct(graph)
      test_pid = self()

      replace_graph_fn = fn group_id, lens_name, data ->
        send(test_pid, {:graph_replaced, group_id, lens_name, data})
        :ok
      end

      assert :ok =
               Graphiti.replace_graph(replaceable_store(:global), graph,
                 replace_graph_fn: replace_graph_fn
               )

      assert_receive {:graph_replaced, "global", "systems", ^data}
    end

    test "and the graph replacement result is returned to the caller" do
      replace_graph_fn = fn _group_id, _lens_name, _data ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.replace_graph(replaceable_store(:global), property_graph(),
                 replace_graph_fn: replace_graph_fn
               )
    end
  end

  describe "when a replaceable Lens store using an application Destination replaces a complete graph" do
    test "then graph replacement receives the group named for that Destination for every operator" do
      test_pid = self()

      replace_graph_fn = fn group_id, _, _ ->
        send(test_pid, {:graph_replaced, group_id})
        :ok
      end

      assert :ok =
               Graphiti.replace_graph(replaceable_store(:application), property_graph(),
                 replace_graph_fn: replace_graph_fn
               )

      assert_receive {:graph_replaced, "systems"}
    end

    test "and graph replacement receives the selected Lens name and supplied nodes and relationships" do
      graph = property_graph()
      data = Map.from_struct(graph)
      test_pid = self()

      replace_graph_fn = fn group_id, lens_name, replacement_data ->
        send(test_pid, {:graph_replaced, group_id, lens_name, replacement_data})
        :ok
      end

      assert :ok =
               Graphiti.replace_graph(replaceable_store(:application), graph,
                 replace_graph_fn: replace_graph_fn
               )

      assert_receive {:graph_replaced, "systems", "systems", ^data}
    end

    test "and the graph replacement result is returned to the caller" do
      replace_graph_fn = fn _, _, _ -> {:error, :graph_unavailable} end

      assert {:error, :graph_unavailable} =
               Graphiti.replace_graph(replaceable_store(:application), property_graph(),
                 replace_graph_fn: replace_graph_fn
               )
    end
  end

  describe "when a replaceable Lens store is searched" do
    test "then graph search receives its resolved Destination group" do
      test_pid = self()

      search_fn = fn group_id, query, max_results ->
        send(test_pid, {:graph_search, group_id, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} =
               Graphiti.search(replaceable_store(:operator), "settlement", 5,
                 search_fn: search_fn
               )

      assert {:ok, []} =
               Graphiti.search(replaceable_store(:global), "settlement", 5, search_fn: search_fn)

      assert_receive {:graph_search, "operator/operator-one", "settlement", 5}

      assert_receive {:graph_search, "global", "settlement", 5}
    end
  end

  defp replaceable_store(scope) do
    %Store{
      operator_id: "operator-one",
      lens: %Replaceable{
        name: "systems",
        destination: destination(destination_name(scope))
      }
    }
  end

  defp lens(name, destination_name),
    do: %Lens{
      name: name,
      destination: destination(destination_name),
      ontology: Strict,
      ingestion: String
    }

  defp destination(name), do: %Destination{name: name}

  defp destination_name(:application), do: "systems"
  defp destination_name(scope), do: Atom.to_string(scope)

  defp property_graph do
    %Gralkor.Graph{
      nodes: [%{id: "system", labels: ["System"], properties: %{name: "payments"}}],
      relationships: []
    }
  end

  defp unsupported_operations(test_pid) do
    add_episode_fn = fn _, _, _, _, _ ->
      send(test_pid, :graphiti_operation_began)
      :ok
    end

    replace_graph_fn = fn _, _, _ ->
      send(test_pid, :graphiti_operation_began)
      :ok
    end

    [
      fn ->
        Graphiti.add_episode(
          %Store{operator_id: "operator-one", lens: lens("observations", "operator")},
          "content",
          "source",
          add_episode_fn: add_episode_fn,
          unsupported_option: true
        )
      end,
      fn ->
        Graphiti.replace_graph(replaceable_store(:operator), property_graph(),
          replace_graph_fn: replace_graph_fn,
          unsupported_option: true
        )
      end
    ]
  end
end
