defmodule Gralkor.OntologyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  describe "when a module declares an ontology with `use Gralkor.Ontology` > if the `:entities` option is not provided" do
    test "then compilation fails with an error naming `:entities` and its allowed values `:strict` and `:open`" do
      assert_raise CompileError, ~r/:entities/, fn ->
        defmodule UseMissingEntities do
          use Gralkor.Ontology, relationships: :scoped
        end
      end
    end

  end

  describe "when a module declares an ontology with `use Gralkor.Ontology` > if the `:entities` option is any value other than `:strict` or `:open`" do
    test "then compilation fails with an error naming `:entities` and the rejected value" do
      assert_raise CompileError, ~r/:entities/, fn ->
        defmodule UseBadEntities do
          use Gralkor.Ontology, entities: :loose, relationships: :scoped
        end
      end
    end

  end

  describe "when a module declares an ontology with `use Gralkor.Ontology` > if the `:relationships` option is not provided" do
    test "then compilation fails with an error naming `:relationships` and its allowed values `:scoped` and `:open`" do
      assert_raise CompileError, ~r/:relationships/, fn ->
        defmodule UseMissingRels do
          use Gralkor.Ontology, entities: :strict
        end
      end
    end

  end

  describe "when a module declares an ontology with `use Gralkor.Ontology` > if the `:relationships` option is any value other than `:scoped` or `:open`" do
    test "then compilation fails with an error naming `:relationships` and the rejected value" do
      assert_raise CompileError, ~r/:relationships/, fn ->
        defmodule UseBadRels do
          use Gralkor.Ontology, entities: :strict, relationships: :loose
        end
      end
    end
  end

  describe "when an ontology declares `entity Foo do … end` with an alias" do
    test "then the entity is named with the alias' last segment as a string (\"Foo\")" do
      defmodule EntityNameOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string)
        end
      end

      assert [%{name: "User"}] = EntityNameOntology.__ontology__().entity_types
    end

    test "and no module named Foo is defined by the declaration" do
      refute Code.ensure_loaded?(Gralkor.OntologyTest.EntityNameOntology.User)
    end

    test "and the entity carries no description, so the extractor decides from the entity's name and fields alone" do
      defmodule NoDescriptionOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string)
        end
      end

      assert [%{description: nil}] = NoDescriptionOntology.__ontology__().entity_types
    end

  end

  describe "when an ontology declares `entity Foo do … end` with an alias > where the declaration passes a description before the block" do
    test "then that description is recorded on the entity, so the extractor is told when to mint it" do
      defmodule DescribedEntityOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User, "A person who talks to the agent." do
          field(:handle, :string)
        end
      end

      assert [%{name: "User", description: "A person who talks to the agent."}] =
               DescribedEntityOntology.__ontology__().entity_types
    end

    test "if the description is neither a string nor absent > then compilation fails with an error naming the entity and the rejected description" do
      assert_raise CompileError, ~r/User.*description.*42/s, fn ->
        defmodule BadDescriptionOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User, 42 do
            field(:handle, :string)
          end
        end
      end
    end

  end

  describe "when an ontology declares `entity Foo do … end` with an alias > where the block calls `field :name, :type`" do
    test "then the entity carries a field with that name and type" do
      defmodule RequiredFieldOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string, required: true)
        end
      end

      [%{fields: [field]}] = RequiredFieldOntology.__ontology__().entity_types
      assert field.name == :handle
      assert field.type == :string
    end

    test "where the call passes `required: true` > then the field is recorded as required" do
      [%{fields: [field]}] = RequiredFieldOntology.__ontology__().entity_types
      assert field == %{name: :handle, type: :string, required: true, doc: nil}
    end

    test "where the call omits `:required` or passes `required: false` > then the field is recorded as optional" do
      defmodule OptionalFieldOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:nickname, :string)
        end
      end

      [%{fields: [field]}] = OptionalFieldOntology.__ontology__().entity_types
      refute field.required
    end

    test "where the call passes `doc: \"…\"` > then the doc string is recorded as the field's description" do
      defmodule DocFieldOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string, doc: "stable login handle")
        end
      end

      [%{fields: [field]}] = DocFieldOntology.__ontology__().entity_types
      assert field.doc == "stable login handle"
    end

    test "where the call omits `:doc` > then the field's description is recorded as nil" do
      [%{fields: [field]}] = OptionalFieldOntology.__ontology__().entity_types
      assert field.doc == nil
    end

    test "if `:type` is outside the supported set (`:string`, `:integer`, `:float`, `:boolean`) > then compilation fails with an error naming the rejected type" do
      assert_raise CompileError, ~r/atom/, fn ->
        defmodule BadTypeOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User do
            field(:handle, :atom)
          end
        end
      end
    end

    test "if `:required` is given a non-boolean value > then compilation fails with an error naming `:required`" do
      assert_raise CompileError, ~r/required/, fn ->
        defmodule InvalidRequiredOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User do
            field(:handle, :string, required: :truthy)
          end
        end
      end
    end

    test "if `:doc` is given a value that is neither a string nor nil > then compilation fails with an error naming `:doc`" do
      assert_raise CompileError, ~r/doc/, fn ->
        defmodule InvalidDocOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User do
            field(:handle, :string, doc: 123)
          end
        end
      end
    end

  end

  describe "when an ontology declares `entity Foo do … end` with an alias > if two fields in the same entity share a name" do
    test "then compilation fails with an error naming the duplicated field" do
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

  end

  describe "when an ontology declares `entity Foo do … end` with an alias > if a relationship-style call appears inside the block" do
    test "then compilation fails, relationships living in `from` blocks" do
      diagnostic =
        capture_io(:stderr, fn ->
          assert_raise CompileError, fn ->
            defmodule RelationshipInsideEntityOntology do
              use Gralkor.Ontology, entities: :open, relationships: :open

              entity User do
                field(:handle, :string)
                prefers(Preference)
              end
            end
          end
        end)

      assert diagnostic =~ "undefined function prefers/1"
    end

  end

  describe "when an ontology declares `entity Foo do … end` with an alias > if the same entity name is declared more than once in one ontology" do
    test "then compilation fails with an error naming the duplicated entity" do
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

  describe "when an ontology declares `from Source do … end` with an alias > where the block calls `verb Target` with no do-block" do
    test "then a relationship is declared from the source entity to the target entity under the verb's edge name" do
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
      assert [{{"User", "Preference"}, ["PREFERS"]}] == ontology.edge_type_map
    end

    test "and that relationship carries no edge properties" do
      assert [%{name: "PREFERS", fields: []}] = BareVerbOntology.__ontology__().edge_types
    end
  end

  describe "when an ontology declares `from Source do … end` with an alias > where the block calls `verb Target do … end`" do
    test "then a relationship is declared from the source entity to the target entity under the verb's edge name" do
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

      assert [{{"User", "Preference"}, ["PREFERS"]}] ==
               EdgePropertyOntology.__ontology__().edge_type_map
    end

    test "and the do-block's `field` declarations become that relationship's edge properties, with the same name, type, required and doc semantics as entity fields" do
      [%{fields: [field]}] = EdgePropertyOntology.__ontology__().edge_types
      assert field == %{name: :since, type: :string, required: false, doc: "date first observed"}
    end
  end

  describe "when an ontology declares `from Source do … end` with an alias > where the verb is a single lowercase word (\"prefers\")" do
    test "then the edge name is that word uppercased (\"PREFERS\")" do
      assert [%{name: "PREFERS"}] = BareVerbOntology.__ontology__().edge_types
    end
  end

  describe "when an ontology declares `from Source do … end` with an alias > where the verb contains underscores (\"relates_to\")" do
    test "then the edge name uppercases each segment and preserves the underscores (\"RELATES_TO\")" do
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
  end

  describe "when an ontology declares `from Source do … end` with an alias > where the verb's target is the source entity itself" do
    test "then the endpoint pair records that entity as both source and target" do
      defmodule SelfReferenceOntology do
        use Gralkor.Ontology, entities: :open, relationships: :scoped

        entity User do
          field(:handle, :string)
        end

        from User do
          trusts(User)
        end
      end

      assert SelfReferenceOntology.__ontology__().edge_type_map == [
               {{"User", "User"}, ["TRUSTS"]}
             ]
    end
  end

  describe "when an ontology declares `from Source do … end` with an alias > where the same verb appears in several `from` blocks with matching edge-property schemas" do
    test "then exactly one edge type is declared for that verb" do
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
    end

    test "and the endpoint map gains one entry per distinct (source, target) pair where the verb appeared, in the order those pairs were declared" do
      ontology = MultiEndpointOntology.__ontology__()
      assert ontology.edge_type_map == [
               {{"User", "Preference"}, ["ENDORSES"]},
               {{"Org", "Preference"}, ["ENDORSES"]}
             ]
    end
  end

  describe "when an ontology declares `from Source do … end` with an alias > if the verb's target is not an alias" do
    test "then compilation fails with an error showing the expected `verb Target` form" do
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
  end

  describe "when an ontology declares `from Source do … end` with an alias > if the same verb is declared again with a differing edge-property schema (field names, types or required flags)" do
    test "then compilation fails with an error naming the conflicting verb" do
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

  end

  describe "when an ontology declares `from Source do … end` with an alias > if the source alias does not name a declared entity" do
    test "then compilation fails at the end of the module naming the unknown source" do
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

  end

  describe "when an ontology declares `from Source do … end` with an alias > if a relationship's target alias does not name a declared entity" do
    test "then compilation fails at the end of the module naming the unknown target" do
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
