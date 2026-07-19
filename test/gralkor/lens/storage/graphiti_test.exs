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

      assert_receive {:graph_add, "lens_6f70657261746f722d6f6e65_6f62736572766174696f6e73", _, _,
                      _, _}
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

    test "and any supplied episode identity is forwarded to graph add as uuid" do
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
                 uuid: "episode-one",
                 add_episode_fn: add_episode_fn
               )

      assert_receive {:graph_add, _, _, _, _, [uuid: "episode-one"]}
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
               Graphiti.add_episode(store, "content", "source", add_episode_fn: add_episode_fn)
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

  describe "when the implicit `default` Lens is added to or searched" do
    test "then graph operations use the operator's existing sanitized destination" do
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

      add_episode_fn = fn destination, _, _, _, _ ->
        send(test_pid, {:graph_add, destination})
        :ok
      end

      search_fn = fn destination, _, _ ->
        send(test_pid, {:graph_search, destination})
        {:ok, []}
      end

      assert :ok =
               Graphiti.add_episode(store, "content", "source", add_episode_fn: add_episode_fn)

      assert {:ok, []} = Graphiti.search(store, "content", 5, search_fn: search_fn)
      assert_receive {:graph_add, "operator_one"}
      assert_receive {:graph_search, "operator_one"}
    end
  end

  describe "when an operator-local Lens store removes an episode" do
    test "then graph removal receives the same operator-and-Lens destination and episode identity" do
      store = %Store{
        operator_id: "operator-one",
        lens: %Lens{
          name: "generalisations",
          ontology: Strict,
          scope: :operator,
          ingestion: Gralkor.Lens.Ingestion.Generalise
        }
      }

      test_pid = self()

      remove_episode_fn = fn destination, episode_id ->
        send(test_pid, {:graph_remove, destination, episode_id})
        :ok
      end

      assert :ok =
               Graphiti.remove_episode(store, "generalisation-one",
                 remove_episode_fn: remove_episode_fn
               )

      assert_receive {:graph_remove,
                      "lens_6f70657261746f722d6f6e65_67656e6572616c69736174696f6e73",
                      "generalisation-one"}
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

    test "and graph add receives the originating Lens as provenance" do
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

      assert_receive {:graph_add, "global", "public fact", "publication", Strict,
                      [lens: "published-observations"]}
    end

    test "and any supplied episode identity is forwarded alongside that provenance as uuid" do
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
                 uuid: "episode-one",
                 add_episode_fn: add_episode_fn
               )

      assert_receive {:graph_add, "global", _, _, _,
                      [uuid: "episode-one", lens: "published-observations"]}
    end
  end

  describe "when the global pool is searched" do
    test "then graph search receives the fixed global destination" do
      store = %Store{operator_id: "operator-one", lens: :global}
      test_pid = self()

      search_fn = fn destination, query, max_results ->
        send(test_pid, {:graph_search, destination, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} = Graphiti.search(store, "launch window", 7, search_fn: search_fn)
      assert_receive {:graph_search, "global", "launch window", 7}
    end

    test "and no originating-Lens filter is supplied" do
      store = %Store{operator_id: "operator-one", lens: :global}
      test_pid = self()

      search_fn = fn destination, query, max_results ->
        send(test_pid, {:graph_search, destination, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} = Graphiti.search(store, "launch window", 7, search_fn: search_fn)
      assert_receive {:graph_search, "global", "launch window", 7}
    end
  end

  describe "when a store bound to a global Lens is searched by its ingestion process" do
    test "then graph search receives the fixed unfiltered global destination" do
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

      search_fn = fn destination, query, max_results ->
        send(test_pid, {:graph_search, destination, query, max_results})
        {:ok, []}
      end

      assert {:ok, []} = Graphiti.search(store, "launch window", 7, search_fn: search_fn)
      assert_receive {:graph_search, "global", "launch window", 7}
    end
  end
end
