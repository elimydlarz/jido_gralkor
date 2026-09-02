defmodule Gralkor.Destination.Storage.GraphitiArtefactTest do
  use ExUnit.Case, async: true

  alias Gralkor.Destination
  alias Gralkor.Artefact
  alias Gralkor.Destination.Storage.Graphiti

  describe "when Graphiti Reflection storage receives an artefact" do
    test "then it supplies the artefact identifier as the requested episode UUID" do
      artefact = artefact()
      test_pid = self()

      add_episode = fn group, content, source, ontology, opts ->
        send(test_pid, {:add_episode, group, content, source, ontology, opts})
        :ok
      end

      assert :ok =
               Graphiti.put_artefact(output(), "review", "operator-one", artefact, add_episode)

      assert_receive {:add_episode, "observations", content, "reflection:review",
                      Gralkor.DefaultOntology, [uuid: "stable-id"]}

      assert Jason.decode!(content) == %{
               "id" => "stable-id",
               "payload" => %{"summary" => "stored"}
             }
    end

    test "then an episode conflict becomes the corresponding artefact conflict" do
      add_episode = fn _group, _content, _source, _ontology, _opts ->
        {:error, {:episode_conflict, "stable-id"}}
      end

      assert {:error, {:artefact_conflict, "stable-id"}} =
               Graphiti.put_artefact(
                 output(),
                 "review",
                 "operator-one",
                 artefact(),
                 add_episode
               )
    end
  end

  describe "when Graphiti Reflection storage looks up an artefact identifier" do
    test "then it returns the matching deserialized artefact" do
      artefact = artefact()

      get_episode = fn "observations", "stable-id" ->
        {:ok,
         %{
           content: Jason.encode!(Map.from_struct(artefact)),
           extraction_complete: true
         }}
      end

      assert {:ok, ^artefact} =
               Graphiti.get_artefact(
                 output(),
                 "review",
                 "operator-one",
                 "stable-id",
                 get_episode
               )
    end

    test "then an unmarked matching episode returns its artefact as incomplete" do
      artefact = artefact()

      get_episode = fn "observations", "stable-id" ->
        {:ok,
         %{
           content: Jason.encode!(Map.from_struct(artefact)),
           extraction_complete: false
         }}
      end

      assert {:error, {:incomplete_artefact, ^artefact}} =
               Graphiti.get_artefact(
                 output(),
                 "review",
                 "operator-one",
                 "stable-id",
                 get_episode
               )
    end

    test "then a missing episode reports not found" do
      get_episode = fn "observations", "missing" -> {:error, :not_found} end

      assert {:error, :not_found} =
               Graphiti.get_artefact(
                 output(),
                 "review",
                 "operator-one",
                 "missing",
                 get_episode
               )
    end

    test "then a mismatched artefact identifier reports a conflict" do
      mismatched_id = %{artefact() | id: "another-id"}

      for stored <- [mismatched_id] do
        get_episode = fn "observations", "stable-id" ->
          {:ok,
           %{
             content: Jason.encode!(Map.from_struct(stored)),
             extraction_complete: true
           }}
        end

        assert {:error, {:artefact_conflict, "stable-id"}} =
                 Graphiti.get_artefact(
                   output(),
                   "review",
                   "operator-one",
                   "stable-id",
                   get_episode
                 )
      end
    end
  end

  defp output,
    do: %{
      kind: :destination,
      destination: %Destination{name: "observations"},
      ontology: Gralkor.DefaultOntology
    }

  defp artefact do
    %Artefact{
      id: "stable-id",
      payload: %{"summary" => "stored"}
    }
  end
end
