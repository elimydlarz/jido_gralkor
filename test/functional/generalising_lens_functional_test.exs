defmodule Gralkor.GeneralisingLensFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Generalisation
  alias Gralkor.Ingest
  alias Gralkor.Lens.Store

  defmodule GeneralisationOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity Generalisation do
      field(:content, :string, required: true)
    end
  end

  setup do
    keys = [
      :lenses,
      :lens_storage,
      :generalise_hypothesise_fn,
      :generalise_evaluate_fn,
      :generalise_min_confidence
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:jido_gralkor, &1)})

    start_supervised!(Gralkor.Lens.Storage.InMemory)

    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
    Application.put_env(:jido_gralkor, :lenses, [lens(:operator)])
    Application.put_env(:jido_gralkor, :generalise_min_confidence, 0.3)

    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    :ok
  end

  describe "when a transcript is submitted through Gralkor's generalising ingestion process" do
    test "and repeated or contradicted facts are reconciled while their source episodes remain as provenance" do
      store = %Store{
        operator_id: "operator-one",
        lens: Client.lens!("generalisations")
      }

      existing = %Generalisation{
        id: "existing-one",
        content: "Eli avoids Friday launches.",
        level: 0,
        confidence: 0.7
      }

      assert :ok =
               Store.add(
                 store,
                 Generalisation.encode(existing),
                 "earlier transcript",
                 uuid: existing.id
               )

      Application.put_env(:jido_gralkor, :generalise_hypothesise_fn, fn _prompt ->
        {:ok, [%{content: "Eli prefers Friday launches.", confidence: 0.9}]}
      end)

      Application.put_env(:jido_gralkor, :generalise_evaluate_fn, fn _prompt ->
        {:ok,
         [
           %{
             action: "contradicts",
             hypothesis_index: 0,
             confidence: 0.9,
             content: "Eli prefers Friday launches.",
             existing_id: "existing-one"
           }
         ]}
      end)

      assert :ok =
               Client.ingest(%Ingest{
                 operator_id: "operator-one",
                 lens: "generalisations",
                 content: "Eli now schedules launches on Friday.",
                 source_description: "new transcript"
               })

      assert [
               %{id: "existing-one"},
               %{content: new_episode, lens: "generalisations"}
             ] = Gralkor.Lens.Storage.InMemory.episodes({"operator-one", "generalisations"})

      assert new_episode =~ "Eli prefers Friday launches."
    end
  end

  defp lens(scope) do
    [
      name: "generalisations",
      ontology: GeneralisationOntology,
      scope: scope,
      ingestion: Gralkor.Lens.Ingestion.Generalise
    ]
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_gralkor, key)
  defp restore_env(key, value), do: Application.put_env(:jido_gralkor, key, value)
end
