defmodule Gralkor.Lens.Storage.InMemoryTest do
  use ExUnit.Case, async: false

  alias Gralkor.Lens
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

    store = %Store{
      operator_id: "operator-one",
      lens: %Lens{
        name: "generalisations",
        ontology: nil,
        scope: :operator,
        ingestion: Gralkor.Lens.Ingestion.Generalise
      }
    }

    %{store: store}
  end

  describe "when a Lens store adds an episode with an explicit identity" do
    test "then the stored episode records that identity", %{store: store} do
      assert :ok = Store.add(store, "encoded generalisation", "generalisation", uuid: "gen-one")

      assert [%{id: "gen-one", content: "encoded generalisation"}] =
               InMemory.episodes({"operator-one", "generalisations"})
    end

    test "and removing that identity removes the same stored episode", %{store: store} do
      assert :ok = Store.add(store, "encoded generalisation", "generalisation", uuid: "gen-one")
      assert :ok = Store.remove(store, "gen-one")
      assert [] = InMemory.episodes({"operator-one", "generalisations"})
    end
  end
end
