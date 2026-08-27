defmodule Gralkor.OntologyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule RequiredFieldOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity User do
      field(:handle, :string, required: true)
    end
  end

  defmodule OptionalFieldOntology do
    use Gralkor.Ontology, entities: :open, relationships: :open

    entity User do
      field(:nickname, :string)
    end
  end

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

  defmodule EmptyOntology do
    use Gralkor.Ontology, entities: :strict, relationships: :scoped
  end

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

  describe "if an ontology entity declaration does not name an alias" do
    test "then compilation fails" do
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule InvalidEntityNameOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open
          entity :user do
          end
        end
        """)
      end
    end

    test "and the error shows the expected entity declaration form" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule InvalidEntityFormOntology do
            use Gralkor.Ontology, entities: :open, relationships: :open
            entity :user do
            end
          end
          """)
        end

      assert Exception.message(error) =~ ~r/entity User(?:, \"…\")? do … end/
    end
  end

  describe "when an ontology declares an aliased entity" do
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

  describe "when an ontology declares an aliased entity > where the entity has a description" do
    test "then that description is recorded for extraction" do
      defmodule DescribedEntityOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User, "A person who talks to the agent." do
          field(:handle, :string)
        end
      end

      assert [%{name: "User", description: "A person who talks to the agent."}] =
               DescribedEntityOntology.__ontology__().entity_types
    end
  end

  describe "when an ontology declares an aliased entity > where the entity has a description > if the description is invalid" do
    test "then compilation fails naming the entity and rejected description" do
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

  describe "when an ontology declares an aliased entity > where the entity declares a field" do
    test "then the entity carries a field with that name and type" do
      [%{fields: [field]}] =
        Gralkor.OntologyTest.RequiredFieldOntology.__ontology__().entity_types

      assert field.name == :handle
      assert field.type == :string
    end
  end

  describe "when an ontology declares an aliased entity > where the entity declares a field > where the call passes `required: true`" do
    test "then the field is recorded as required" do
      ontology_module = Gralkor.OntologyTest.RequiredFieldOntology
      [%{fields: [field]}] = apply(ontology_module, :__ontology__, []).entity_types
      assert field == %{name: :handle, type: :string, required: true, doc: nil}
    end
  end

  describe "when an ontology declares an aliased entity > where the entity declares a field > where the call omits `:required` or passes `required: false`" do
    test "then the field is recorded as optional" do
      [%{fields: [field]}] =
        Gralkor.OntologyTest.OptionalFieldOntology.__ontology__().entity_types

      refute field.required
    end
  end

  describe "when an ontology declares an aliased entity > where the entity declares a field > where the call passes `doc: \"…\"`" do
    test "then the doc string is recorded as the field's description" do
      defmodule DocFieldOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string, doc: "stable login handle")
        end
      end

      [%{fields: [field]}] = DocFieldOntology.__ontology__().entity_types
      assert field.doc == "stable login handle"
    end
  end

  describe "when an ontology declares an aliased entity > where the entity declares a field > where the call omits `:doc`" do
    test "then the field's description is recorded as nil" do
      ontology_module = Gralkor.OntologyTest.OptionalFieldOntology
      [%{fields: [field]}] = apply(ontology_module, :__ontology__, []).entity_types
      assert field.doc == nil
    end
  end

  describe "when an ontology declares an aliased entity > where the entity declares a field > if the field type is unsupported" do
    test "then compilation fails naming the rejected type" do
      assert_raise CompileError, ~r/atom/, fn ->
        defmodule BadTypeOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User do
            field(:handle, :atom)
          end
        end
      end
    end
  end

  describe "when an ontology declares an aliased entity > where the entity declares a field > if `:required` is given a non-boolean value" do
    test "then compilation fails with an error naming `:required`" do
      assert_raise CompileError, ~r/required/, fn ->
        defmodule InvalidRequiredOntology do
          use Gralkor.Ontology, entities: :open, relationships: :open

          entity User do
            field(:handle, :string, required: :truthy)
          end
        end
      end
    end
  end

  describe "when an ontology declares an aliased entity > where the entity declares a field > if `:doc` is given a value that is neither a string nor nil" do
    test "then compilation fails with an error naming `:doc`" do
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

  describe "when an ontology declares an aliased entity > if two fields in the same entity share a name" do
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

  describe "when an ontology declares an aliased entity > if a relationship-style call appears inside the block" do
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

  describe "when an ontology declares an aliased entity > if the same entity name is declared more than once in one ontology" do
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

  describe "when an ontology declares an aliased relationship source > where the block calls `verb Target` with no do-block" do
    test "then a relationship is declared from the source entity to the target entity under the verb's edge name" do
      ontology = BareVerbOntology.__ontology__()
      assert [{{"User", "Preference"}, ["PREFERS"]}] == ontology.edge_type_map
    end

    test "and that relationship carries no edge properties" do
      ontology_module = Gralkor.OntologyTest.BareVerbOntology

      assert [%{name: "PREFERS", fields: []}] =
               apply(ontology_module, :__ontology__, []).edge_types
    end
  end

  describe "when an ontology declares an aliased relationship source > where the block calls `verb Target do … end`" do
    test "then a relationship is declared from the source entity to the target entity under the verb's edge name" do
      assert [{{"User", "Preference"}, ["PREFERS"]}] ==
               EdgePropertyOntology.__ontology__().edge_type_map
    end

    test "and the do-block fields become edge properties with entity-field semantics" do
      ontology_module = Gralkor.OntologyTest.EdgePropertyOntology
      [%{fields: [field]}] = apply(ontology_module, :__ontology__, []).edge_types
      assert field == %{name: :since, type: :string, required: false, doc: "date first observed"}
    end
  end

  describe "when an ontology declares an aliased relationship source > where the verb is a single lowercase word (\"prefers\")" do
    test "then the edge name is that word uppercased (\"PREFERS\")" do
      ontology_module = Gralkor.OntologyTest.BareVerbOntology
      assert [%{name: "PREFERS"}] = apply(ontology_module, :__ontology__, []).edge_types
    end
  end

  describe "when an ontology declares an aliased relationship source > where the verb contains underscores (\"relates_to\")" do
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

  describe "when an ontology declares an aliased relationship source > where the verb's target is the source entity itself" do
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

  describe "when an ontology declares an aliased relationship source > where matching relationship verbs span several source blocks" do
    test "then exactly one edge type is declared for that verb" do
      ontology = Gralkor.OntologyTest.MultiEndpointOntology.__ontology__()
      assert [%{name: "ENDORSES"}] = ontology.edge_types
    end

    test "and the endpoint map preserves each distinct declared source-target pair in order" do
      ontology_module = Gralkor.OntologyTest.MultiEndpointOntology
      ontology = apply(ontology_module, :__ontology__, [])

      assert ontology.edge_type_map == [
               {{"User", "Preference"}, ["ENDORSES"]},
               {{"Org", "Preference"}, ["ENDORSES"]}
             ]
    end
  end

  describe "when an ontology declares an aliased relationship source > if the verb's target is not an alias" do
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

  describe "when an ontology declares an aliased relationship source > if repeated verbs have different edge-property schemas" do
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

  describe "when an ontology declares an aliased relationship source > if the source alias does not name a declared entity" do
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

  describe "when an ontology declares an aliased relationship source > if a relationship's target alias does not name a declared entity" do
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

  describe "while an ontology is declared with `entities: :strict`" do
    test "then `__ontology__/0` returns `[\"Entity\"]` for `:excluded_entity_types`, so only declared types are extracted" do
      defmodule StrictEntitiesOntology do
        use Gralkor.Ontology, entities: :strict, relationships: :open

        entity User do
          field(:handle, :string)
        end
      end

      assert StrictEntitiesOntology.__ontology__().excluded_entity_types == ["Entity"]
    end
  end

  describe "while an ontology is declared with `entities: :open`" do
    test "then `__ontology__/0` returns nil for `:excluded_entity_types`, leaving generic Entity extraction enabled" do
      defmodule OpenEntitiesOntology do
        use Gralkor.Ontology, entities: :open, relationships: :open

        entity User do
          field(:handle, :string)
        end
      end

      assert OpenEntitiesOntology.__ontology__().excluded_entity_types == nil
    end
  end

  describe "while an ontology is declared with `relationships: :open` > where relationships were declared" do
    test "then `__ontology__/0` returns an empty `:edge_type_map`, so every named edge stays allowed everywhere" do
      ontology = Gralkor.OntologyTest.OpenRelsOntology.__ontology__()
      assert ontology.edge_type_map == []
    end

    test "but the declared verbs still appear in `:edge_types`" do
      ontology_module = Gralkor.OntologyTest.OpenRelsOntology
      ontology = apply(ontology_module, :__ontology__, [])
      assert [%{name: "PREFERS"}] = ontology.edge_types
    end
  end

  describe "while an ontology declares no entities and no relationships" do
    test "then `__ontology__/0` still returns a valid payload with an empty `:entity_types`" do
      assert EmptyOntology.__ontology__().entity_types == []
    end

    test "and an empty `:edge_types`" do
      ontology_module = Gralkor.OntologyTest.EmptyOntology
      assert apply(ontology_module, :__ontology__, []).edge_types == []
    end

    test "and an empty `:edge_type_map`" do
      ontology_module = Gralkor.OntologyTest.EmptyOntology
      assert apply(ontology_module, :__ontology__, []).edge_type_map == []
    end

    test "and an `:excluded_entity_types` that still follows the declared `:entities` option" do
      ontology_module = Gralkor.OntologyTest.EmptyOntology
      assert apply(ontology_module, :__ontology__, []).excluded_entity_types == ["Entity"]
    end
  end

  describe "when a consumer reads a declared ontology" do
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

    test "then it returns a map whose keys are exactly `:entity_types`, `:edge_types`, `:edge_type_map` and `:excluded_entity_types`" do
      assert Map.keys(SusuLikeOntology.__ontology__()) |> Enum.sort() ==
               [:edge_type_map, :edge_types, :entity_types, :excluded_entity_types]
    end

    test "and `:entity_types` lists one `%{name: String.t(), fields: [field()]}` entry per declared entity, in declaration order" do
      ontology = SusuLikeOntology.__ontology__()
      assert Enum.map(ontology.entity_types, & &1.name) == ["User", "Preference"]
    end

    test "and `:edge_types` lists one `%{name: String.t(), fields: [field()]}` entry per declared verb, deduplicated across `from` blocks" do
      ontology = SusuLikeOntology.__ontology__()
      assert Enum.map(ontology.edge_types, & &1.name) |> Enum.sort() == ["PREFERS", "TRUSTS"]
    end

    test "and `:edge_types` preserves the verbs' first-declaration order" do
      ontology = SusuLikeOntology.__ontology__()
      assert Enum.map(ontology.edge_types, & &1.name) == ["PREFERS", "TRUSTS"]
    end

    test "and `:edge_type_map` lists `{{source_name, target_name}, [edge_name]}` pairs preserving declaration order across `from` blocks" do
      ontology = SusuLikeOntology.__ontology__()

      assert ontology.edge_type_map == [
               {{"User", "Preference"}, ["PREFERS"]},
               {{"User", "User"}, ["TRUSTS"]}
             ]
    end

    test "and each field entry is `%{name: atom(), type: atom(), required: boolean(), doc: String.t() | nil}`" do
      ontology = SusuLikeOntology.__ontology__()

      assert hd(hd(ontology.entity_types).fields) == %{
               name: :handle,
               type: :string,
               required: true,
               doc: "stable login handle"
             }
    end
  end

  describe "while an ontology is declared with `relationships: :scoped`" do
    test "then `__ontology__/0` returns exactly the declared (source, target) → [edge_name] entries in `:edge_type_map`" do
      assert Gralkor.OntologyTest.SusuLikeOntology.__ontology__().edge_type_map == [
               {{"User", "Preference"}, ["PREFERS"]},
               {{"User", "User"}, ["TRUSTS"]}
             ]
    end
  end
end
