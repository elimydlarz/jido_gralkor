defmodule Gralkor.Reflection.Registry do
  @moduledoc false

  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Destination.Registry, as: DestinationRegistry

  @built_in_definitions [
    [
      name: "generalisations",
      triggers: [{:lens_ingestion, :any}],
      chain_of_thought: "priv/reflections/generalisations.yaml",
      destination: "global",
      ontology: Gralkor.DefaultOntology
    ],
    [
      name: "erl",
      triggers: [{:lens_ingestion, :any}],
      chain_of_thought: "priv/reflections/erl.yaml",
      destination: "operator",
      ontology: Gralkor.Reflection.ERLOntology
    ]
  ]

  @doc "Returns the application's validated Reflection declarations."
  def configured! do
    case Application.fetch_env(:jido_gralkor, :reflections) do
      :error -> configured!(@built_in_definitions)
      {:ok, reflections} -> configured!(reflections)
    end
  end

  defp configured!(reflections) do
    case reflections do
      reflections when is_list(reflections) ->
        if Enum.all?(reflections, &match?(%Reflection{}, &1)) do
          validate_resolved!(reflections)
        else
          root =
            Application.get_env(
              :jido_gralkor,
              :reflection_root,
              Application.app_dir(:jido_gralkor)
            )

          load!(reflections, root: root)
        end

      invalid ->
        raise ArgumentError, "invalid Reflection declarations: #{inspect(invalid)}"
    end
  end

  def load(definitions, opts \\ [])

  def load(definitions, opts) when is_list(definitions) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    with :ok <- validate_names(definitions),
         {:ok, reflections} <- load_all(definitions, root) do
      {:ok, reflections}
    end
  end

  def load(definitions, _opts), do: {:error, {:invalid_reflections, definitions}}

  def load!(definitions, opts \\ []) do
    case load(definitions, opts) do
      {:ok, reflections} ->
        reflections

      {:error, reason} ->
        raise ArgumentError, "invalid Reflection declaration: #{inspect(reason)}"
    end
  end

  defp validate_resolved!(reflections) do
    result =
      with :ok <- validate_names(reflections) do
        Enum.reduce_while(reflections, :ok, fn reflection, :ok ->
          case validate_resolved(reflection) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end

    case result do
      :ok ->
        reflections

      {:error, reason} ->
        raise ArgumentError, "invalid Reflection declaration: #{inspect(reason)}"
    end
  end

  defp validate_resolved(%Reflection{} = reflection) do
    name = reflection.name

    cond do
      not match?(%Gralkor.Destination{}, reflection.destination) ->
        {:error, {:missing_destination, name, reflection.destination}}

      not valid_ontology?(reflection.ontology) ->
        {:error, {:invalid_ontology, name, reflection.ontology}}

      true ->
        fetch_destination!(name, reflection.destination.name)

        case ChainOfThought.validate(reflection.chain_of_thought) do
          :ok -> :ok
          {:error, reason} -> {:error, {:invalid_chain_of_thought, name, reason}}
        end
    end
  end

  defp validate_names(definitions) do
    names = Enum.map(definitions, &field(&1, :name))

    cond do
      invalid = Enum.find(names, &(not non_blank?(&1))) -> {:error, {:blank_name, invalid}}
      duplicate = duplicate(names) -> {:error, {:duplicate_name, duplicate}}
      true -> :ok
    end
  end

  defp load_all(definitions, root) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, acc} ->
      case load_one(definition, root) do
        {:ok, reflection} -> {:cont, {:ok, acc ++ [reflection]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_one(definition, root) do
    name = field(definition, :name)
    destination = field(definition, :destination)
    ontology = field(definition, :ontology) || Gralkor.DefaultOntology
    triggers = field(definition, :triggers)
    relative = field(definition, :chain_of_thought)

    cond do
      not is_list(triggers) or triggers == [] ->
        {:error, {:missing_triggers, name}}

      invalid_trigger = Enum.find(triggers, &(not supported_trigger?(&1))) ->
        {:error, {:invalid_trigger, name, invalid_trigger}}

      is_nil(relative) ->
        {:error, {:missing_chain_of_thought, name}}

      not non_blank?(relative) ->
        {:error, {:invalid_chain_of_thought_file, name, relative}}

      not non_blank?(destination) ->
        {:error, {:missing_destination, name, destination}}

      not valid_ontology?(ontology) ->
        {:error, {:invalid_ontology, name, ontology}}

      true ->
        load_cot(
          name,
          destination,
          ontology,
          triggers,
          relative,
          root
        )
    end
  end

  defp load_cot(name, destination_name, ontology, triggers, relative, root) do
    path = Path.expand(relative, root)

    cond do
      not repository_path?(path, root) or Path.extname(path) not in [".yaml", ".yml"] ->
        {:error, {:invalid_chain_of_thought_file, name, relative}}

      true ->
        case ChainOfThought.load(path) do
          {:ok, cot} ->
            {:ok,
             %Reflection{
               name: name,
               destination: fetch_destination!(name, destination_name),
               ontology: ontology,
               chain_of_thought: cot,
               triggers: triggers
             }}

          {:error, reason} ->
            {:error, {:invalid_chain_of_thought, name, relative, reason}}
        end
    end
  end

  defp repository_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp fetch_destination!(reflection_name, destination_name) do
    DestinationRegistry.fetch!(destination_name)
  rescue
    error in ArgumentError ->
      if Exception.message(error) == "unknown Destination #{inspect(destination_name)}" do
        raise ArgumentError,
              "Reflection #{inspect(reflection_name)} references unknown Destination #{inspect(destination_name)}"
      else
        reraise error, __STACKTRACE__
      end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(keyword, key) when is_list(keyword), do: Keyword.get(keyword, key)
  defp field(_, _), do: nil

  defp supported_trigger?(:programmatic), do: true
  defp supported_trigger?({:lens_ingestion, :any}), do: true
  defp supported_trigger?({:lens_ingestion, lenses}) when is_list(lenses), do: true

  defp supported_trigger?(_trigger), do: false

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
