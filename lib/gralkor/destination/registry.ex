defmodule Gralkor.Destination.Registry do
  @moduledoc false

  alias Gralkor.Destination

  @packaged [
    %Destination{
      name: "operator",
      address: "operator/memory",
      ontology: Gralkor.DefaultOntology
    },
    %Destination{
      name: "experiential-learning",
      address: "operator/experiential-learning",
      ontology: Gralkor.Reflection.ERLOntology
    },
    %Destination{
      name: "generalisations",
      address: "global/generalisations",
      ontology: Gralkor.DefaultOntology
    }
  ]

  def configured! do
    case Application.get_env(:jido_gralkor, :destinations, []) do
      definitions when is_list(definitions) ->
        destinations = @packaged ++ Enum.map(definitions, &resolve!/1)
        validate_unique_names!(destinations)
        destinations

      invalid -> raise ArgumentError, "Destination registry must be a list, got #{inspect(invalid)}"
    end
  end

  def fetch!(name) when is_binary(name) do
    case Enum.find(configured!(), &(&1.name == name)) do
      nil -> raise ArgumentError, "unknown Destination #{inspect(name)}"
      destination -> destination
    end
  end

  defp resolve!(definition) when is_list(definition) do
    unless Keyword.keyword?(definition) do
      raise ArgumentError, "invalid Destination definition #{inspect(definition)}"
    end

    name = Keyword.get(definition, :name)

    unless is_binary(name) and String.trim(name) != "" do
      raise ArgumentError, "invalid Destination name #{inspect(name)}"
    end

    address = Keyword.get(definition, :address)
    validate_address!(name, address)

    ontology = Keyword.get(definition, :ontology, Gralkor.DefaultOntology)
    validate_ontology!(name, ontology)

    %Destination{
      name: name,
      address: address,
      ontology: ontology
    }
  end

  defp resolve!(definition),
    do: raise(ArgumentError, "invalid Destination definition #{inspect(definition)}")

  defp validate_address!(name, address) when is_binary(address) do
    case String.split(address, "/", parts: 2) do
      [scope, path] when scope in ["operator", "global"] ->
        if String.trim(path) == "" do
          raise ArgumentError,
                "invalid Destination #{inspect(name)} address #{inspect(address)}: path must be non-blank"
        end

      _ ->
        raise ArgumentError,
              "invalid Destination #{inspect(name)} address #{inspect(address)}: expected operator/path or global/path"
    end
  end

  defp validate_address!(name, address) do
    raise ArgumentError, "invalid Destination #{inspect(name)} address #{inspect(address)}"
  end

  defp validate_ontology!(name, ontology) do
    unless is_atom(ontology) and Code.ensure_loaded?(ontology) and
             function_exported?(ontology, :__ontology__, 0) do
      raise ArgumentError, "invalid Destination #{inspect(name)} ontology #{inspect(ontology)}"
    end
  end

  defp validate_unique_names!(destinations) do
    destinations
    |> Enum.group_by(& &1.name)
    |> Enum.find(fn {_name, definitions} -> length(definitions) > 1 end)
    |> case do
      nil -> :ok
      {name, _} -> raise ArgumentError, "duplicate Destination #{inspect(name)}"
    end
  end
end
