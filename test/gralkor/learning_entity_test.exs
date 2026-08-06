defmodule Gralkor.LearningEntityTest do
  use ExUnit.Case, async: true

  alias Gralkor.LearningEntity

  describe "when the built-in learning entity type is requested" do
    test "then it is named \"Learning\"" do
      assert %{name: "Learning"} = LearningEntity.spec()
    end

    test "and it carries a non-empty description, without which the extraction model never mints a learning node" do
      assert %{description: description} = LearningEntity.spec()
      assert String.length(description) > 0
    end

    test "and it declares the problem kind, the approach, the success flag, and the lesson, in that order" do
      assert %{fields: fields} = LearningEntity.spec()

      field_names = Enum.map(fields, & &1.name)
      assert field_names == [:problem_kind, :approach, :success, :lesson]
    end

    test "and the problem kind is an optional string, so extraction never drops the entity over a missing attribute" do
      field = find_field(LearningEntity.spec(), :problem_kind)
      assert field.type == :string
      assert field.required == false
    end

    test "and the approach is an optional string" do
      field = find_field(LearningEntity.spec(), :approach)
      assert field.type == :string
      assert field.required == false
    end

    test "and the success flag is an optional boolean" do
      field = find_field(LearningEntity.spec(), :success)
      assert field.type == :boolean
      assert field.required == false
    end

    test "and the lesson is an optional string" do
      field = find_field(LearningEntity.spec(), :lesson)
      assert field.type == :string
      assert field.required == false
    end

    test "and no field takes a name the graph store reserves for itself" do
      protected = [
        :uuid,
        :name,
        :group_id,
        :labels,
        :created_at,
        :summary,
        :attributes,
        :name_embedding
      ]

      field_names = Enum.map(LearningEntity.spec().fields, & &1.name)

      for p <- protected do
        refute p in field_names, "Learning field #{inspect(p)} is a Graphiti-protected name"
      end
    end
  end

  describe "when a consumer's entity-type list is merged with the built-in learning entity type > while the list declares no entity named \"Learning\"" do
    test "then the learning entry is appended after every entry the consumer declared" do
      consumer = [
        %{name: "User", fields: [%{name: :handle, type: :string, required: true, doc: nil}]}
      ]

      result = LearningEntity.merge_entity_types(consumer)

      assert length(result) == 2
      assert hd(result) == hd(consumer)
      assert List.last(result) == LearningEntity.spec()
    end

  end

  describe "when a consumer's entity-type list is merged with the built-in learning entity type > while the list declares no entity types at all" do
    test "then the learning entry is the only entry returned" do
      assert LearningEntity.merge_entity_types([]) == [LearningEntity.spec()]
    end
  end

  describe "when a consumer's entity-type list is merged with the built-in learning entity type > if the list already declares an entity named \"Learning\"" do
    test "then the list is returned unchanged, so a consumer's own learning entity is never overridden" do
      learning = LearningEntity.spec()
      consumer = [%{name: "User", fields: []}, learning]
      assert LearningEntity.merge_entity_types(consumer) == consumer
    end
  end

  describe "when a consumer ontology payload is merged with the built-in learning entity type" do
    setup do
      payload = %{
        entity_types: [%{name: "User", fields: []}],
        edge_types: [%{name: "PREFERS", fields: []}],
        edge_type_map: [{{"User", "Preference"}, ["PREFERS"]}],
        excluded_entity_types: ["Entity"]
      }

      result = LearningEntity.merge_ontology_payload(payload)

      %{payload: payload, result: result}
    end

    test "then the payload's entity types gain the learning entry", %{result: result} do
      assert List.last(result.entity_types) == LearningEntity.spec()
      assert length(result.entity_types) == 2
    end

    test "and the payload's edge types, edge-type map, and excluded entity types are preserved unchanged", %{
      payload: payload,
      result: result
    } do
      assert result.edge_types == payload.edge_types
      assert result.edge_type_map == payload.edge_type_map
      assert result.excluded_entity_types == payload.excluded_entity_types
    end
  end

  describe "while no consumer ontology payload is supplied > when the built-in learning entity type is merged" do
    test "then a payload carrying only the learning entity type is returned, so learning extraction is not gated on a configured ontology" do
      result = LearningEntity.merge_ontology_payload(nil)

      assert result.entity_types == [LearningEntity.spec()]
    end

    test "and that payload declares no edge types, no edge-type map, and no excluded entity types" do
      result = LearningEntity.merge_ontology_payload(nil)

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
