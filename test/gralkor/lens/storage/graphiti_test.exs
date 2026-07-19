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
                      "The launch window moved to Friday.", "project update", Strict, []}
    end
  end
end
