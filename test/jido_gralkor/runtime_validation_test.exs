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
          outputs: [[kind: :destination, destination: "memory", ontology: Gralkor.DefaultOntology]],
          chain_of_thought: [
            steps: [[label: "inspect", directions: "Inspect.", output: %{"summary" => "string"}]]
          ]
        ]
      ]
    }

    definitions = Map.fetch!(base, collection)
    definition = List.first(definitions)
    definition = Keyword.put(definition, :name, value)
    definitions = if Keyword.get(options, :duplicate), do: [definition, definition], else: [definition]
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

  defp parse_chain_of_thought([steps: [step]]), do: parse_chain_of_thought(%{steps: [step]})
end
