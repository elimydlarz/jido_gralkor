defmodule Gralkor.Reflection.Registry do
  @moduledoc false

  alias Gralkor.Destination.Registry, as: DestinationRegistry
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Reflection.Packaged

  @lens_provenance_delimiter " [lens: "

  @doc "Returns the package-owned structured Reflection declarations."
  def configured!, do: load!(Packaged.definitions())

  @doc false
  def load(definitions) when is_list(definitions) do
    with :ok <- validate_names(definitions) do
      Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, reflections} ->
        case load_one(definition) do
          {:ok, reflection} -> {:cont, {:ok, reflections ++ [reflection]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def load(definitions), do: {:error, {:invalid_reflections, definitions}}

  @doc false
  def load!(definitions) do
    case load(definitions) do
      {:ok, reflections} -> reflections
      {:error, reason} -> raise ArgumentError, "invalid Reflection declaration: #{inspect(reason)}"
    end
  end

  defp load_one(definition) when is_map(definition) or is_list(definition) do
    name = field(definition, :name)
    outputs = field(definition, :outputs)
    chain_of_thought = field(definition, :chain_of_thought)

    with :ok <- validate_outputs(name, outputs),
         {:ok, chain_of_thought} <- resolve_chain_of_thought(name, chain_of_thought) do
      {:ok,
       %Reflection{
         name: name,
         chain_of_thought: chain_of_thought,
         outputs: Enum.map(outputs, &resolve_output(name, &1))
       }}
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_destination, name, Exception.message(error)}}
  end

  defp load_one(definition), do: {:error, {:invalid_reflection, definition}}

  defp resolve_chain_of_thought(name, nil), do: {:error, {:missing_chain_of_thought, name}}

  defp resolve_chain_of_thought(name, configuration)
       when is_map(configuration) or is_list(configuration) do
    case ChainOfThought.from_config(configuration) do
      {:ok, chain_of_thought} -> {:ok, chain_of_thought}
      {:error, reason} -> {:error, {:invalid_chain_of_thought, name, reason}}
    end
  end

  defp resolve_chain_of_thought(name, configured),
    do: {:error, {:invalid_chain_of_thought, name, configured}}

  defp validate_names(definitions) do
    names = Enum.map(definitions, &field(&1, :name))

    cond do
      invalid = Enum.find(names, &(not non_blank?(&1))) ->
        {:error, {:blank_name, invalid}}

      reserved =
          Enum.find(names, &(is_binary(&1) and String.contains?(&1, @lens_provenance_delimiter))) ->
        {:error, {:reserved_provenance_syntax, reserved, @lens_provenance_delimiter}}

      duplicate = duplicate(names) ->
        {:error, {:duplicate_name, duplicate}}

      true ->
        :ok
    end
  end

  defp validate_outputs(name, outputs) when not is_list(outputs),
    do: {:error, {:invalid_outputs, name, outputs}}

  defp validate_outputs(name, outputs) do
    destination_outputs = Enum.filter(outputs, &(field(&1, :kind) == :destination))
    unsupported = Enum.find(outputs, &(field(&1, :kind) != :destination))
    destination = List.first(destination_outputs)
    destination_name = field(destination, :destination)
    ontology = field(destination, :ontology) || Gralkor.DefaultOntology

    cond do
      destination_outputs == [] ->
        {:error, {:missing_destination_output, name}}

      length(destination_outputs) > 1 ->
        {:error, {:duplicate_output, name, :destination}}

      unsupported ->
        {:error, {:unsupported_output, name, field(unsupported, :kind)}}

      not non_blank?(destination_name) ->
        {:error, {:missing_destination, name, destination_name}}

      not valid_ontology?(ontology) ->
        {:error, {:invalid_ontology, name, ontology}}

      true ->
        :ok
    end
  end

  defp resolve_output(reflection_name, output) do
    destination_name = field(output, :destination)

    %{
      kind: :destination,
      destination: fetch_destination!(reflection_name, destination_name),
      ontology: field(output, :ontology) || Gralkor.DefaultOntology
    }
  end

  defp fetch_destination!(reflection_name, destination_name) do
    DestinationRegistry.fetch!(destination_name)
  rescue
    error in ArgumentError ->
      raise ArgumentError,
            "Reflection #{inspect(reflection_name)} references unknown Destination #{inspect(destination_name)}: #{Exception.message(error)}"
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(keyword, key) when is_list(keyword), do: Keyword.get(keyword, key)
  defp field(_, _), do: nil

  defp duplicate(values) do
    values
    |> Enum.frequencies()
    |> Enum.find_value(fn {value, count} -> if count > 1, do: value end)
  end

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_ontology?(ontology) do
    is_atom(ontology) and Code.ensure_loaded?(ontology) and
      function_exported?(ontology, :__ontology__, 0)
  end
end
