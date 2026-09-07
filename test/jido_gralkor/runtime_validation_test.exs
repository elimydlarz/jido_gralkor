defmodule JidoGralkor.RuntimeValidationTest do
  use ExUnit.Case, async: true

  alias JidoGralkor.Runtime

  describe "if runtime configuration is not a map" do
    test "then validation identifies the configured value" do
      assert {:error, {:invalid_configuration, :not_a_map}} = validate(:not_a_map)
    end
  end

  describe "if a Destination, Lens, or Reflection name is missing, blank, or duplicated" do
    for collection <- [:destinations, :lenses, :reflections], value <- [nil, false, "", "  "] do
      test "then validation identifies #{collection} name #{inspect(value)}" do
        configuration = valid_configuration(unquote(collection), unquote(value))

        assert {:error, {:blank_definition_name, unquote(collection), unquote(value)}} =
                 validate(configuration)
      end
    end
  end

  describe "if a Destination, Lens, or Reflection name is duplicated" do
    for collection <- [:destinations, :lenses, :reflections] do
      test "then validation identifies the duplicate #{collection} name" do
        configuration = valid_configuration(unquote(collection), "same", duplicate: true)

        assert {:error, {:duplicate_definition_name, unquote(collection), "same"}} =
                 validate(configuration)
      end
    end
  end

  describe "top-level and collection validation" do
    test "identifies every unknown top-level field" do
      assert {:error, {:unknown_configuration_fields, [:extra, :other]}} =
               validate(Map.merge(valid_configuration(:destinations, "memory"), %{extra: 1, other: 2}))
    end

    for collection <- [:destinations, :lenses, :reflections] do
      test "identifies missing #{collection} collection" do
        assert {:error, {:missing_collection, unquote(collection)}} =
                 validate(Map.delete(valid_configuration(:destinations, "memory"), unquote(collection)))
      end

      test "identifies invalid #{collection} collection" do
        assert {:error, {:invalid_collection, unquote(collection), :bad}} =
                 validate(Map.put(valid_configuration(:destinations, "memory"), unquote(collection), :bad))
      end
    end

    test "identifies a definition with the collection and configured value" do
      assert {:error, {:invalid_definition, :destinations, :bad}} =
               validate(Map.put(valid_configuration(:destinations, "memory"), :destinations, [:bad]))
    end

    test "identifies unknown definition fields" do
      configuration = update_in(valid_configuration(:destinations, "memory"), [:destinations, Access.at(0)], &Keyword.put(&1, :extra, true))
      assert {:error, {:unknown_definition_fields, :destinations, "memory", [:extra]}} = validate(configuration)
    end
  end

  describe "reserved names and destination references" do
    test "identifies a package-owned name" do
      assert {:error, {:reserved_definition_name, :destinations, "operator"}} =
               validate(Map.put(valid_configuration(:destinations, "memory"), :destinations, [[name: "operator"]]))
    end

    test "identifies the reserved destination namespace" do
      assert {:error, {:reserved_destination_namespace, "operator/custom"}} =
               validate(Map.put(valid_configuration(:destinations, "memory"), :destinations, [[name: "operator/custom"]]))
    end

    test "identifies the retired default Lens name" do
      assert {:error, {:retired_definition_name, :lenses, "default", "operator"}} =
               validate(Map.put(valid_configuration(:destinations, "memory"), :lenses, [[name: "default", destination: "memory", write: :append, ingestion: Gralkor.Lens.Ingestion.Store, ontology: Gralkor.DefaultOntology]]))
    end

    test "identifies reserved provenance syntax" do
      assert {:error, {:reserved_provenance_syntax, :lenses, "notes [lens: old"}} =
               validate(Map.put(valid_configuration(:destinations, "memory"), :lenses, [[name: "notes [lens: old", destination: "memory", write: :append, ingestion: Gralkor.Lens.Ingestion.Store, ontology: Gralkor.DefaultOntology]]))
    end

    test "identifies an unknown Lens Destination" do
      configuration = update_in(valid_configuration(:destinations, "memory"), [:lenses, Access.at(0)], &Keyword.put(&1, :destination, "missing"))
      assert {:error, {:unknown_destination, :lenses, "notes", "missing"}} = validate(configuration)
    end
  end

  describe "Lens shape validation" do
    test "accepts a valid appending Lens" do
      assert :ok = validate(valid_configuration(:destinations, "memory"))
    end

    test "rejects invalid ingestion, ontology, incompatible fields, and write mode" do
      base = valid_configuration(:destinations, "memory")
      bad_ingestion = update_in(base, [:lenses, Access.at(0)], &Keyword.put(&1, :ingestion, String))
      assert {:error, {:invalid_lens_ingestion, "notes", String}} = validate(bad_ingestion)
      bad_ontology = update_in(base, [:lenses, Access.at(0)], &Keyword.put(&1, :ontology, String))
      assert {:error, {:invalid_lens_ontology, "notes", String}} = validate(bad_ontology)
      replace = update_in(base, [:lenses, Access.at(0)], fn lens -> lens |> Keyword.put(:write, :replace_graph) |> Keyword.delete(:ontology) |> Keyword.delete(:ingestion) end)
      assert :ok = validate(replace)
      incompatible = update_in(replace, [:lenses, Access.at(0)], &Keyword.put(&1, :ontology, Gralkor.DefaultOntology))
      assert {:error, {:incompatible_lens_definition, "notes"}} = validate(incompatible)
      invalid_write = update_in(base, [:lenses, Access.at(0)], &Keyword.put(&1, :write, :other))
      assert {:error, {:invalid_lens_write, "notes", :other}} = validate(invalid_write)
    end
  end

  describe "Reflection output and Chain of Thought validation" do
    test "identifies invalid outputs and output counts" do
      base = valid_configuration(:destinations, "memory")
      assert {:error, {:invalid_reflection_outputs, "review", :bad}} = validate(update_in(base, [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, :bad)))
      missing = update_in(base, [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, []))
      assert {:error, {:missing_destination_output, "review"}} = validate(missing)
      duplicate = update_in(base, [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, [[kind: :destination, destination: "memory", ontology: Gralkor.DefaultOntology], [kind: :destination, destination: "memory", ontology: Gralkor.DefaultOntology]]))
      assert {:error, {:duplicate_destination_output, "review"}} = validate(duplicate)
      unsupported = update_in(base, [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, [[kind: :other]]))
      assert {:error, {:unsupported_reflection_output, "review", :other}} = validate(unsupported)
    end

    test "identifies invalid output fields and Chain of Thought declarations" do
      base = valid_configuration(:destinations, "memory")
      missing_destination = update_in(base, [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, [[kind: :destination, ontology: Gralkor.DefaultOntology]]))
      assert {:error, {:missing_reflection_destination, "review", nil}} = validate(missing_destination)
      unknown_destination = update_in(base, [:reflections, Access.at(0)], &Keyword.put(&1, :outputs, [[kind: :destination, destination: "missing", ontology: Gralkor.DefaultOntology]]))
      assert {:error, {:unknown_destination, :reflections, "review", "missing"}} = validate(unknown_destination)
      missing_cot = update_in(base, [:reflections, Access.at(0)], &Keyword.delete(&1, :chain_of_thought))
      assert {:error, {:missing_chain_of_thought, "review"}} = validate(missing_cot)
      bad_cot = update_in(base, [:reflections, Access.at(0)], &Keyword.put(&1, :chain_of_thought, :bad))
      assert {:error, {:invalid_chain_of_thought, "review", :bad}} = validate(bad_cot)
      unknown_cot = update_in(base, [:reflections, Access.at(0)], &Keyword.put(&1, :chain_of_thought, [steps: [], extra: true]))
      assert {:error, {:unknown_chain_of_thought_fields, "review", [:extra]}} = validate(unknown_cot)
    end
  end

  defp validate(configuration) do
    Runtime.validate(configuration,
      packaged_reflections: fn -> [] end,
      parse_chain_of_thought: &parse_chain_of_thought/1
    )
  end

  defp valid_configuration(collection, value, options \\ []) do
    base = %{
      destinations: [[name: "memory"]],
      lenses: [
        [
          name: "notes",
          destination: "memory",
          write: :append,
          ingestion: Gralkor.Lens.Ingestion.Store,
          ontology: Gralkor.DefaultOntology
        ]
      ],
      reflections: [
        [
          name: "review",
          outputs: [
            [kind: :destination, destination: "memory", ontology: Gralkor.DefaultOntology]
          ],
          chain_of_thought: [
            steps: [[label: "inspect", directions: "Inspect.", output: %{"summary" => "string"}]]
          ]
        ]
      ]
    }

    definitions = Map.fetch!(base, collection)
    definition = List.first(definitions)
    definition = Keyword.put(definition, :name, value)

    definitions =
      if Keyword.get(options, :duplicate), do: [definition, definition], else: [definition]

    Map.put(base, collection, definitions)
  end

  defp parse_chain_of_thought(%{
         steps: [
           %{
             label: "inspect",
             directions: "Inspect the supplied evidence.",
             output: %{"summary" => "string"}
           }
         ]
       }) do
    {:ok,
     %Gralkor.Reflection.ChainOfThought{
       steps: [
         %Gralkor.Reflection.ChainOfThought.Step{
           label: "inspect",
           directions: "Inspect the supplied evidence.",
           output: %{"summary" => "string"}
         }
       ]
     }}
  end

  defp parse_chain_of_thought(steps: [step]), do: parse_chain_of_thought(%{steps: [step]})
end
