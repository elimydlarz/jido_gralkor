defmodule Gralkor.OntologyGraphitiSpecTest do
  use ExUnit.Case, async: true

  alias Gralkor.GraphitiPool

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{entity_types: [], edge_types: [], edge_type_map: [], excluded_entity_types: nil},
      overrides
    )
  end

  describe "ex-ontology-graphiti-spec > entity_types / edge_types > when the payload declares entities" do
    test "then the spec carries :entity_types as a list of name/fields maps in declaration order" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            entity_types: [
              %{name: "User", fields: [%{name: :handle, type: :string, required: true, doc: "h"}]},
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

  describe "ex-ontology-graphiti-spec > entity_types / edge_types > when the payload declares no entities" do
    test "then the spec omits :entity_types entirely" do
      refute Map.has_key?(GraphitiPool.graphiti_boundary_spec(payload()), :entity_types)
    end
  end

  describe "ex-ontology-graphiti-spec > entity_types / edge_types > when the payload declares relationship verbs" do
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

  describe "ex-ontology-graphiti-spec > entity_types / edge_types > when the payload declares no relationship verbs" do
    test "then the spec omits :edge_types entirely" do
      refute Map.has_key?(GraphitiPool.graphiti_boundary_spec(payload()), :edge_types)
    end
  end

  describe "ex-ontology-graphiti-spec > entity_types / edge_types > a field entry > when a field is required" do
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

  describe "ex-ontology-graphiti-spec > entity_types / edge_types > a field entry > when a field is optional" do
    test "then its entry carries \"required\" => false" do
      spec =
        GraphitiPool.graphiti_boundary_spec(
          payload(%{
            entity_types: [
              %{name: "User", fields: [%{name: :nickname, type: :string, required: false, doc: nil}]}
            ]
          })
        )

      [%{"fields" => [field]}] = spec[:entity_types]
      assert field["required"] == false
    end
  end

  describe "ex-ontology-graphiti-spec > entity_types / edge_types > a field entry > when a field has a doc string" do
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

  describe "ex-ontology-graphiti-spec > entity_types / edge_types > a field entry > when a field has no doc string" do
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

  describe "ex-ontology-graphiti-spec > edge_type_map > when the payload's :edge_type_map is non-empty" do
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

  describe "ex-ontology-graphiti-spec > edge_type_map > when the payload's :edge_type_map is []" do
    test "then the spec omits :edge_type_map entirely" do
      refute Map.has_key?(GraphitiPool.graphiti_boundary_spec(payload()), :edge_type_map)
    end
  end

  describe "ex-ontology-graphiti-spec > excluded_entity_types > when the payload's :excluded_entity_types is [\"Entity\"]" do
    test "then the spec carries :excluded_entity_types as [\"Entity\"]" do
      spec = GraphitiPool.graphiti_boundary_spec(payload(%{excluded_entity_types: ["Entity"]}))
      assert spec[:excluded_entity_types] == ["Entity"]
    end
  end

  describe "ex-ontology-graphiti-spec > excluded_entity_types > when the payload's :excluded_entity_types is nil" do
    test "then the spec omits :excluded_entity_types entirely" do
      refute Map.has_key?(
               GraphitiPool.graphiti_boundary_spec(payload(%{excluded_entity_types: nil})),
               :excluded_entity_types
             )
    end
  end

  describe "ex-ontology-graphiti-spec > empty ontology > when the payload declares no entities, no verbs, and :excluded_entity_types is nil" do
    test "then the spec is empty — add_episode is invoked with none of the four ontology kwargs" do
      assert GraphitiPool.graphiti_boundary_spec(payload()) == %{}
    end
  end

  describe "ex-ontology-graphiti-spec > empty ontology > when the payload declares nothing but :excluded_entity_types is [\"Entity\"]" do
    test "then the spec carries only :excluded_entity_types" do
      spec = GraphitiPool.graphiti_boundary_spec(payload(%{excluded_entity_types: ["Entity"]}))
      assert spec == %{excluded_entity_types: ["Entity"]}
    end
  end
end
