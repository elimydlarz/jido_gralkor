defmodule Gralkor.OntologyGraphitiSpecTest do
  use ExUnit.Case, async: true

  alias Gralkor.GraphitiPool

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{entity_types: [], edge_types: [], edge_type_map: [], excluded_entity_types: nil},
      overrides
    )
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload declares entities" do
    test "then the spec carries :entity_types as a list of name/fields maps in declaration order" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            entity_types: [
              %{
                name: "User",
                fields: [%{name: :handle, type: :string, required: true, doc: "h"}]
              },
              %{name: "Preference", fields: []}
            ]
          })
        )

      assert spec[:entity_types] == [
               %{
                 "name" => "User",
                 "fields" => [
                   %{"name" => "handle", "type" => "string", "required" => true, "doc" => "h"}
                 ]
               },
               %{"name" => "Preference", "fields" => []}
             ]
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while a projected type carries a description" do
    test "then that type's entry carries `\"description\" =>` that string" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            entity_types: [
              %{name: "User", description: "A person who talks to the agent.", fields: []}
            ]
          })
        )

      assert spec[:entity_types] == [
               %{
                 "name" => "User",
                 "description" => "A person who talks to the agent.",
                 "fields" => []
               }
             ]
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while a projected type carries no description" do
    test "then that type's entry omits `\"description\"` entirely" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{entity_types: [%{name: "Preference", description: nil, fields: []}]})
        )

      assert spec[:entity_types] == [%{"name" => "Preference", "fields" => []}]
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload declares no entities" do
    test "then the spec omits :entity_types entirely" do
      refute Map.has_key?(GraphitiPool.graphiti_boundary_spec(payload()), :entity_types)
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload declares relationship verbs" do
    test "then the spec carries :edge_types as a list of name/fields maps in first-declaration order" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            edge_types: [
              %{name: "PREFERS", fields: []},
              %{name: "KNOWS", fields: []}
            ]
          })
        )

      assert spec[:edge_types] == [
               %{"name" => "PREFERS", "fields" => []},
               %{"name" => "KNOWS", "fields" => []}
             ]
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload declares no relationship verbs" do
    test "then the spec omits :edge_types entirely" do
      refute Map.has_key?(GraphitiPool.graphiti_boundary_spec(payload()), :edge_types)
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while a projected type carries a required field" do
    test "then its entry carries \"required\" => true" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            entity_types: [
              %{name: "User", fields: [%{name: :handle, type: :string, required: true, doc: nil}]}
            ]
          })
        )

      [%{"fields" => [field]}] = spec[:entity_types]
      assert field["required"] == true
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while a projected type carries an optional field" do
    test "then its entry carries \"required\" => false" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            entity_types: [
              %{
                name: "User",
                fields: [%{name: :nickname, type: :string, required: false, doc: nil}]
              }
            ]
          })
        )

      [%{"fields" => [field]}] = spec[:entity_types]
      assert field["required"] == false
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while a projected type carries a field with a doc string" do
    test "then its entry carries \"doc\" => that string" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            entity_types: [
              %{
                name: "User",
                fields: [%{name: :handle, type: :string, required: true, doc: "stable handle"}]
              }
            ]
          })
        )

      [%{"fields" => [field]}] = spec[:entity_types]
      assert field["doc"] == "stable handle"
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while a projected type carries a field with no doc string" do
    test "then its entry carries \"doc\" => nil" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            entity_types: [
              %{name: "User", fields: [%{name: :handle, type: :string, required: true, doc: nil}]}
            ]
          })
        )

      [%{"fields" => [field]}] = spec[:entity_types]
      assert field["doc"] == nil
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload's `:edge_type_map` is non-empty" do
    test "then the spec carries :edge_type_map as a list of src/dst/names maps in order" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            edge_type_map: [
              {{"User", "Preference"}, ["PREFERS"]},
              {{"User", "Topic"}, ["KNOWS"]}
            ]
          })
        )

      assert spec[:edge_type_map] == [
               %{"src" => "User", "dst" => "Preference", "names" => ["PREFERS"]},
               %{"src" => "User", "dst" => "Topic", "names" => ["KNOWS"]}
             ]
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload's `:edge_type_map` is empty" do
    test "then the spec omits :edge_type_map entirely" do
      refute Map.has_key?(GraphitiPool.graphiti_boundary_spec(payload()), :edge_type_map)
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload's `:excluded_entity_types` is `[\"Entity\"]`" do
    test "then the spec carries :excluded_entity_types as [\"Entity\"]" do
      spec = GraphitiPool.graphiti_boundary_spec(payload(%{excluded_entity_types: ["Entity"]}))
      assert spec[:excluded_entity_types] == ["Entity"]
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload's `:excluded_entity_types` is nil" do
    test "then the spec omits :excluded_entity_types entirely" do
      refute Map.has_key?(
               GraphitiPool.graphiti_boundary_spec(payload(%{excluded_entity_types: nil})),
               :excluded_entity_types
             )
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload declares no entities and no verbs > where its `:excluded_entity_types` is nil" do
    test "then the spec is empty" do
      assert GraphitiPool.graphiti_boundary_spec(payload()) == %{}
    end
  end

  describe "when a caller projects an ontology payload into the graphiti boundary spec > while the payload declares no entities and no verbs > where its `:excluded_entity_types` is `[\"Entity\"]`" do
    test "then the spec carries only :excluded_entity_types" do
      spec = GraphitiPool.graphiti_boundary_spec(payload(%{excluded_entity_types: ["Entity"]}))
      assert spec == %{excluded_entity_types: ["Entity"]}
    end
  end
end
