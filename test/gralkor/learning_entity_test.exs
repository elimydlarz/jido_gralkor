defmodule Gralkor.LearningEntityTest do
  use ExUnit.Case, async: true

  alias Gralkor.LearningEntity

  describe "ex-learning-entity > spec/0" do
    test "returns the entity-types entry for Learning" do
      assert %{name: "Learning", fields: fields} = LearningEntity.spec()

      field_names = Enum.map(fields, & &1.name)
      assert field_names == [:problem_kind, :approach, :success, :lesson]
    end

    test "problem_kind is a required string" do
      field = find_field(LearningEntity.spec(), :problem_kind)
      assert field.type == :string
      assert field.required == true
    end

    test "approach is a required string" do
      field = find_field(LearningEntity.spec(), :approach)
      assert field.type == :string
      assert field.required == true
    end

    test "success is a required boolean" do
      field = find_field(LearningEntity.spec(), :success)
      assert field.type == :boolean
      assert field.required == true
    end

    test "lesson is a required string" do
      field = find_field(LearningEntity.spec(), :lesson)
      assert field.type == :string
      assert field.required == true
    end

    test "no field name is Graphiti-protected" do
      protected = [:uuid, :name, :group_id, :labels, :created_at, :summary, :attributes, :name_embedding]
      field_names = Enum.map(LearningEntity.spec().fields, & &1.name)

      for p <- protected do
        refute p in field_names, "Learning field #{inspect(p)} is a Graphiti-protected name"
      end
    end
  end

  describe "ex-learning-entity > merge_entity_types/1" do
    test "appends Learning to an empty list" do
      assert LearningEntity.merge_entity_types([]) == [LearningEntity.spec()]
    end

    test "appends Learning after a consumer's existing entities" do
      consumer = [%{name: "User", fields: [%{name: :handle, type: :string, required: true, doc: nil}]}]
      result = LearningEntity.merge_entity_types(consumer)

      assert length(result) == 2
      assert hd(result) == hd(consumer)
      assert List.last(result) == LearningEntity.spec()
    end

    test "returns the list unchanged when Learning is already present" do
      learning = LearningEntity.spec()
      consumer = [%{name: "User", fields: []}, learning]
      assert LearningEntity.merge_entity_types(consumer) == consumer
    end
  end

  describe "ex-learning-entity > merge_ontology_payload/1" do
    test "merges Learning into a consumer payload, preserving the other three keys" do
      payload = %{
        entity_types: [%{name: "User", fields: []}],
        edge_types: [%{name: "PREFERS", fields: []}],
        edge_type_map: [{{"User", "Preference"}, ["PREFERS"]}],
        excluded_entity_types: ["Entity"]
      }

      result = LearningEntity.merge_ontology_payload(payload)

      assert result.edge_types == payload.edge_types
      assert result.edge_type_map == payload.edge_type_map
      assert result.excluded_entity_types == payload.excluded_entity_types
      assert List.last(result.entity_types) == LearningEntity.spec()
      assert length(result.entity_types) == 2
    end

    test "with nil, returns a payload carrying only the Learning entity_types entry" do
      result = LearningEntity.merge_ontology_payload(nil)

      assert result.entity_types == [LearningEntity.spec()]
      assert result.edge_types == []
      assert result.edge_type_map == []
      assert result.excluded_entity_types == nil
    end
  end

  defp find_field(spec, name) do
    Enum.find(spec.fields, &(&1.name == name)) ||
      flunk("expected field #{inspect(name)} on Learning spec")
  end
end
