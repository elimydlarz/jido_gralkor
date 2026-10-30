defmodule Gralkor.Lens.Storage.GraphitiTest do
  use ExUnit.Case, async: true

  alias Gralkor.Lens
  alias Gralkor.Destination
  alias Gralkor.Lens.Storage.Graphiti
  alias Gralkor.Lens.Store
  alias Gralkor.TestOntologies.Strict

  describe "when a Lens store adds an episode to the `personal` Destination" do
    test "then Graphiti receives the group named `personal/<operator id>`" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "personal")
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

      assert_receive {:graph_add, "personal/operator-one", _, _, _, _}
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
          lens: lens("observations", "personal")
        },
        %Store{
          operator_id: "operator-two",
          lens: lens("observations", "personal")
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
        lens: lens("observations", "personal")
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
                      Strict, _}
    end

    test "and the graph add receives the originating Lens name" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "personal")
      }

      test_pid = self()

      add_episode_fn = fn _group_id, _content, _source_description, _ontology, opts ->
        send(test_pid, {:graph_opts, opts})
        :ok
      end

      assert :ok =
               Graphiti.add_episode(store, "content", "source", add_episode_fn: add_episode_fn)

      assert_receive {:graph_opts, opts}
      assert opts[:lens] == "observations"
    end

    test "and the graph add result is returned to the ingestion process" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "personal")
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
        lens: lens("observations", "personal"),
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

  describe "if a Lens store receives an unsupported addition or search option" do
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

  describe "when a Lens store using the `personal` Destination is searched" do
    test "then graph search receives the same resolved group" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "personal")
      }

      test_pid = self()

      search_fn = fn group_id, query, max_results ->
        send(test_pid, {:graph_search, group_id, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} =
               Graphiti.search(store, "launch window", 7, search_fn: search_fn)

      assert_receive {:graph_search, "personal/operator-one", _, _}
    end

    test "and graph search receives the query and result limit" do
      store = %Store{
        operator_id: "operator-one",
        lens: lens("observations", "personal")
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
        lens: lens("observations", "personal")
      }

      search_fn = fn _group_id, _query, _max_results ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.search(store, "launch window", 7, search_fn: search_fn)
    end
  end

  describe "when the packaged `personal-chat` Lens's packaged Destination is added to or searched" do
    test "then graph operations use the group named `personal/<operator id>`" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "personal-chat",
          destination: destination("personal"),
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
      assert_receive {:graph_add, "personal/operator-one"}
      assert_receive {:graph_search, "personal/operator-one"}
    end
  end

  describe "when a Lens store adds an episode to the `global` Destination" do
    test "then graph add receives the group named `global` for every operator" do
      test_pid = self()

      add_episode_fn = fn group_id, _content, _source_description, _ontology, _opts ->
        send(test_pid, {:graph_add, group_id})
        :ok
      end

      for operator_id <- ["operator-one", "operator-two"] do
        store = %Store{
          operator_id: operator_id,
          lens: lens("published-observations", "global")
        }

        assert :ok =
                 Graphiti.add_episode(store, "public fact", "publication",
                   add_episode_fn: add_episode_fn
                 )

        assert_receive {:graph_add, "global"}
      end
    end
  end

  describe "when a Lens store adds an episode to an application Destination" do
    test "then graph add receives the group named for that Destination for every operator" do
      test_pid = self()

      add_episode_fn = fn group_id, _, _, _, _ ->
        send(test_pid, {:graph_add, group_id})
        :ok
      end

      for operator_id <- ["operator-one", "operator-two"] do
        store = %Store{operator_id: operator_id, lens: lens("observations", "observations")}

        assert :ok =
                 Graphiti.add_episode(store, "fact", "source", add_episode_fn: add_episode_fn)

        assert_receive {:graph_add, "observations"}
      end
    end
  end

  defp lens(name, destination_name),
    do: %Lens{
      name: name,
      destination: destination(destination_name),
      ontology: Strict,
      ingestion: String
    }

  defp destination(name), do: %Destination{name: name}

  defp unsupported_operations(test_pid) do
    add_episode_fn = fn _, _, _, _, _ ->
      send(test_pid, :graphiti_operation_began)
      :ok
    end

    search_fn = fn _, _, _ ->
      send(test_pid, :graphiti_operation_began)
      {:ok, []}
    end

    [
      fn ->
        Graphiti.add_episode(
          %Store{operator_id: "operator-one", lens: lens("observations", "personal")},
          "content",
          "source",
          add_episode_fn: add_episode_fn,
          unsupported_option: true
        )
      end,
      fn ->
        Graphiti.search(
          %Store{operator_id: "operator-one", lens: lens("observations", "personal")},
          "launch window",
          5,
          search_fn: search_fn,
          unsupported_option: true
        )
      end
    ]
  end
end
