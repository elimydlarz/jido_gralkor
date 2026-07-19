defmodule Gralkor.Lens.Storage.GraphitiTest do
  use ExUnit.Case, async: true

  alias Gralkor.Lens
  alias Gralkor.Lens.Storage.Graphiti
  alias Gralkor.Lens.Store
  alias Gralkor.TestOntologies.Strict

  describe "when an operator-local Lens store adds an episode" do
    test "then the graph add receives a deterministic destination unique to the operator and Lens" do
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

      add_episode_fn = fn destination, content, source_description, ontology, opts ->
        send(
          test_pid,
          {:graph_add, destination, content, source_description, ontology, opts}
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

      assert_receive {:graph_add,
                      "lens_6f70657261746f722d6f6e65_6f62736572766174696f6e73",
                      _, _, _, _}
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

      add_episode_fn = fn destination, content, source_description, ontology, opts ->
        send(
          test_pid,
          {:graph_add, destination, content, source_description, ontology, opts}
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

      add_episode_fn = fn _destination, _content, _source_description, _ontology, _opts ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.add_episode(store, "content", "source",
                 add_episode_fn: add_episode_fn
               )
    end
  end

  describe "when an operator-local Lens store is searched" do
    test "then graph search receives the same deterministic operator-and-Lens destination" do
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

      search_fn = fn destination, query, max_results ->
        send(test_pid, {:graph_search, destination, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} =
               Graphiti.search(store, "launch window", 7, search_fn: search_fn)

      assert_receive {:graph_search,
                      "lens_6f70657261746f722d6f6e65_6f62736572766174696f6e73", _, _}
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

      search_fn = fn destination, query, max_results ->
        send(test_pid, {:graph_search, destination, query, max_results})
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

      search_fn = fn _destination, _query, _max_results ->
        {:error, :graph_unavailable}
      end

      assert {:error, :graph_unavailable} =
               Graphiti.search(store, "launch window", 7, search_fn: search_fn)
    end
  end

  describe "when a global Lens store adds an episode" do
    test "then graph add receives the fixed global destination" do
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

      add_episode_fn = fn destination, content, source_description, ontology, opts ->
        send(
          test_pid,
          {:graph_add, destination, content, source_description, ontology, opts}
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
end
