defmodule Gralkor.OntologyTest do
  use ExUnit.Case, async: true

  describe "ex-ontology > use opts validation" do
    test "missing :entities raises CompileError" do
      assert_raise CompileError, ~r/:entities/, fn ->
        defmodule UseMissingEntities do
          use Gralkor.Ontology, relationships: :scoped
        end
      end
    end

    test "bad :entities value raises CompileError" do
      assert_raise CompileError, ~r/:entities/, fn ->
        defmodule UseBadEntities do
          use Gralkor.Ontology, entities: :loose, relationships: :scoped
        end
      end
    end

    test "missing :relationships raises CompileError" do
      assert_raise CompileError, ~r/:relationships/, fn ->
        defmodule UseMissingRels do
          use Gralkor.Ontology, entities: :strict
        end
      end
    end

    test "bad :relationships value raises CompileError" do
      assert_raise CompileError, ~r/:relationships/, fn ->
        defmodule UseBadRels do
          use Gralkor.Ontology, entities: :strict, relationships: :loose
        end
      end
    end
  end

  describe "ex-ontology > entity declarations" do
    test "alias becomes the entity's string name" do
      defmodule EntityNameOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string)
        end
      end

      assert [%{name: "User"}] = EntityNameOntology.__ontology__().entity_types
    end

    test "field with required: true records required" do
      defmodule RequiredFieldOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string, required: true)
        end
      end

      [%{fields: [field]}] = RequiredFieldOntology.__ontology__().entity_types
      assert field == %{name: :handle, type: :string, required: true, doc: nil}
    end

    test "field defaults to optional and nil doc" do
      defmodule OptionalFieldOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:nickname, :string)
        end
      end

      [%{fields: [field]}] = OptionalFieldOntology.__ontology__().entity_types
      assert field == %{name: :nickname, type: :string, required: false, doc: nil}
    end

    test "field doc is recorded" do
      defmodule DocFieldOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string, doc: "stable login handle")
        end
      end

      [%{fields: [field]}] = DocFieldOntology.__ontology__().entity_types
      assert field.doc == "stable login handle"
    end

    test "unsupported field type raises" do
      assert_raise CompileError, ~r/atom/, fn ->
        defmodule BadTypeOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User do
            field(:handle, :atom)
          end
        end
      end
    end

    test "duplicate field name in same entity raises" do
      assert_raise CompileError, ~r/handle/, fn ->
        defmodule DuplicateFieldOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User do
            field(:handle, :string)
            field(:handle, :string)
          end
        end
      end
    end

    test "duplicate entity declarations raise" do
      assert_raise CompileError, ~r/User/, fn ->
        defmodule DuplicateEntityOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User do
            field(:handle, :string)
          end

          entity User do
            field(:handle, :string)
          end
        end
      end
    end
  end

  describe "ex-ontology > from blocks" do
    test "bare verb produces a relationship with uppercase edge name and no fields" do
      defmodule BareVerbOntology do
        use Gralkor.Ontology, entities: :open, relationships: :scoped

        entity User do
          field(:handle, :string)
        end

        entity Preference do
          field(:description, :string)
        end

        from User do
          prefers(Preference)
        end
      end

      ontology = BareVerbOntology.__ontology__()
      assert [%{name: "PREFERS", fields: []}] = ontology.edge_types
      assert [{{"User", "Preference"}, ["PREFERS"]}] == ontology.edge_type_map
    end

    test "verb with do-block carries edge property fields" do
      defmodule EdgePropertyOntology do
        use Gralkor.Ontology, entities: :open, relationships: :scoped

        entity User do
          field(:handle, :string)
        end

        entity Preference do
          field(:description, :string)
        end

        from User do
          prefers Preference do
            field(:since, :string, doc: "date first observed")
          end
        end
      end

      [%{fields: [field]}] = EdgePropertyOntology.__ontology__().edge_types
      assert field == %{name: :since, type: :string, required: false, doc: "date first observed"}
    end

    test "verb with underscores uppercases each segment" do
      defmodule UnderscoreVerbOntology do
        use Gralkor.Ontology, entities: :open, relationships: :scoped

        entity Node do
          field(:label, :string)
        end

        from Node do
          relates_to(Node)
        end
      end

      [edge_type] = UnderscoreVerbOntology.__ontology__().edge_types
      assert edge_type.name == "RELATES_TO"
    end

    test "same verb across multiple from blocks unions endpoints under one edge type" do
      defmodule MultiEndpointOntology do
        use Gralkor.Ontology, entities: :open, relationships: :scoped

        entity User do
          field(:handle, :string)
        end

        entity Org do
          field(:name, :string)
        end

        entity Preference do
          field(:description, :string)
        end

        from User do
          endorses(Preference)
        end

        from Org do
          endorses(Preference)
        end
      end

      ontology = MultiEndpointOntology.__ontology__()
      assert [%{name: "ENDORSES"}] = ontology.edge_types

      assert ontology.edge_type_map == [
               {{"User", "Preference"}, ["ENDORSES"]},
               {{"Org", "Preference"}, ["ENDORSES"]}
             ]
    end

    test "conflicting property schemas across blocks raise" do
      assert_raise CompileError, ~r/conflicting/, fn ->
        defmodule ConflictEdgeOntology do
          use Gralkor.Ontology, entities: :open, relationships: :scoped

          entity User do
            field(:handle, :string)
          end

          entity Preference do
            field(:description, :string)
          end

          from User do
            prefers Preference do
              field(:since, :string)
            end
          end

          from User do
            prefers Preference do
              field(:strength, :string)
            end
          end
        end
      end
    end

    test "unknown source entity raises" do
      assert_raise CompileError, ~r/Ghost/, fn ->
        defmodule UnknownSourceOntology do
          use Gralkor.Ontology, entities: :open, relationships: :scoped

          entity Preference do
            field(:description, :string)
          end

          from Ghost do
            prefers(Preference)
          end
        end
      end
    end

    test "unknown target entity raises" do
      assert_raise CompileError, ~r/Ghost/, fn ->
        defmodule UnknownTargetOntology do
          use Gralkor.Ontology, entities: :open, relationships: :scoped

          entity User do
            field(:handle, :string)
          end

          from User do
            knows(Ghost)
          end
        end
      end
    end

    test "target that is not an alias raises" do
      assert_raise CompileError, ~r/verb Target/, fn ->
        defmodule NonAliasTargetOntology do
          use Gralkor.Ontology, entities: :open, relationships: :scoped

          entity User do
            field(:handle, :string)
          end

          from User do
            knows("Ghost")
          end
        end
      end
    end

    test "self-reference works (e.g. trusts User inside from User)" do
      defmodule SelfReferenceOntology do
        use Gralkor.Ontology, entities: :open, relationships: :scoped

        entity User do
          field(:handle, :string)
        end

        from User do
          trusts(User)
        end
      end

      ontology = SelfReferenceOntology.__ontology__()
      assert ontology.edge_type_map == [{{"User", "User"}, ["TRUSTS"]}]
    end
  end

  describe "ex-ontology-payload > excluded_entity_types" do
    test "entities: :strict sets [\"Entity\"]" do
      defmodule StrictEntitiesOntology do
        use Gralkor.Ontology, entities: :strict, relationships: :open

        entity User do
          field(:handle, :string)
        end
      end

      assert StrictEntitiesOntology.__ontology__().excluded_entity_types == ["Entity"]
    end

    test "entities: :open sets nil" do
      defmodule OpenEntitiesOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string)
        end
      end

      assert OpenEntitiesOntology.__ontology__().excluded_entity_types == nil
    end
  end

  describe "ex-ontology-payload > edge_type_map" do
    test "relationships: :open empties the map even when relationships are declared" do
      defmodule OpenRelsOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string)
        end

        entity Preference do
          field(:description, :string)
        end

        from User do
          prefers(Preference)
        end
      end

      ontology = OpenRelsOntology.__ontology__()
      assert ontology.edge_type_map == []
      assert [%{name: "PREFERS"}] = ontology.edge_types
    end
  end

  describe "ex-ontology-payload > empty ontology" do
    test "no entities and no relationships still produces a valid payload" do
      defmodule EmptyOntology do
        use Gralkor.Ontology, entities: :strict, relationships: :scoped
      end

      assert EmptyOntology.__ontology__() == %{
               entity_types: [],
               edge_types: [],
               edge_type_map: [],
               excluded_entity_types: ["Entity"]
             }
    end
  end

  describe "ex-ontology > integration example" do
    defmodule SusuLikeOntology do
      use Gralkor.Ontology, entities: :strict, relationships: :scoped

      entity User do
        field(:handle, :string, required: true, doc: "stable login handle")
        field(:timezone, :string, doc: "IANA tz")
      end

      entity Preference do
        field(:description, :string, required: true)
      end

      from User do
        prefers Preference do
          field(:since, :string, doc: "date first observed")
        end

        trusts(User)
      end
    end

    test "entity_types preserves declaration order" do
      ontology = SusuLikeOntology.__ontology__()
      assert Enum.map(ontology.entity_types, & &1.name) == ["User", "Preference"]
    end

    test "edge_types covers both declared verbs" do
      ontology = SusuLikeOntology.__ontology__()
      assert Enum.map(ontology.edge_types, & &1.name) |> Enum.sort() == ["PREFERS", "TRUSTS"]
    end

    test "edge_type_map covers both (User, Preference) and (User, User)" do
      ontology = SusuLikeOntology.__ontology__()
      assert {{"User", "Preference"}, ["PREFERS"]} in ontology.edge_type_map
      assert {{"User", "User"}, ["TRUSTS"]} in ontology.edge_type_map
    end

    test "excluded_entity_types reflects :strict" do
      ontology = SusuLikeOntology.__ontology__()
      assert ontology.excluded_entity_types == ["Entity"]
    end
  end
end
