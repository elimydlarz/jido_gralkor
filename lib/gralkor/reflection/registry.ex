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
      outputs: [
        [kind: :destination, destination: "global", ontology: Gralkor.DefaultOntology]
      ]
    ],
    [
      name: "erl",
      triggers: [{:lens_ingestion, :any}],
      chain_of_thought: "priv/reflections/erl.yaml",
      outputs: [
        [
          kind: :destination,
          destination: "operator",
          ontology: Gralkor.Reflection.ERLOntology
        ]
      ]
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
    output_error = output_error(name, reflection.outputs)

    cond do
      output_error ->
        {:error, output_error}

      true ->
        reflection.outputs
        |> Enum.find(&(&1.kind == :destination))
        |> Map.fetch!(:destination)
        |> then(&fetch_destination!(name, &1.name))

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
    outputs = field(definition, :outputs)
    triggers = field(definition, :triggers)
    relative = field(definition, :chain_of_thought)
    lens_error = named_lens_error(name, triggers)
    output_error = output_error(name, outputs)

    cond do
      not is_list(triggers) or triggers == [] ->
        {:error, {:missing_triggers, name}}

      invalid_trigger = Enum.find(triggers, &(not supported_trigger?(&1))) ->
        {:error, {:invalid_trigger, name, invalid_trigger}}

      Enum.any?(triggers, &match?({:lens_ingestion, []}, &1)) ->
        {:error, {:empty_lens_selection, name}}

      lens_error ->
        {:error, lens_error}

      output_error ->
        {:error, output_error}

      is_nil(relative) ->
        {:error, {:missing_chain_of_thought, name}}

      not non_blank?(relative) ->
        {:error, {:invalid_chain_of_thought_file, name, relative}}

      true ->
        load_cot(name, outputs, triggers, relative, root)
    end
  end

  defp load_cot(name, outputs, triggers, relative, root) do
    path = Path.expand(relative, root)

    cond do
      not repository_path?(path, root) or Path.extname(path) not in [".yaml", ".yml"] ->
        {:error, {:invalid_chain_of_thought_file, name, relative}}

      true ->
        case ChainOfThought.load(path) do
          {:ok, cot} ->
            resolved_outputs = resolve_outputs(name, outputs)

            {:ok,
             %Reflection{
               name: name,
               chain_of_thought: cot,
               outputs: resolved_outputs,
               triggers: triggers
             }}

          {:error, reason} ->
            {:error, {:invalid_chain_of_thought, name, relative, reason}}
        end
    end
  end

  defp resolve_outputs(name, outputs) do
    Enum.map(outputs, fn output ->
      case field(output, :kind) do
        :destination ->
          destination_output(
            name,
            field(output, :destination),
            field(output, :ontology) || Gralkor.DefaultOntology
          )

        :return ->
          %{kind: :return, handler: field(output, :handler)}
      end
    end)
  end

  defp destination_output(name, destination_name, ontology) do
    %{
      kind: :destination,
      destination: fetch_destination!(name, destination_name),
      ontology: ontology
    }
  end

  defp output_error(name, outputs) when not is_list(outputs),
    do: {:invalid_outputs, name, outputs}

  defp output_error(name, outputs) do
    destination_outputs = Enum.filter(outputs, &(field(&1, :kind) == :destination))
    return_outputs = Enum.filter(outputs, &(field(&1, :kind) == :return))
    unsupported = Enum.find(outputs, &(field(&1, :kind) not in [:destination, :return]))
    destination = List.first(destination_outputs)
    destination_name = field(destination, :destination)
    ontology = field(destination, :ontology) || Gralkor.DefaultOntology
    return_output = List.first(return_outputs)
    handler = field(return_output, :handler)

    cond do
      destination_outputs == [] -> {:missing_destination_output, name}
      length(destination_outputs) > 1 -> {:duplicate_output, name, :destination}
      length(return_outputs) > 1 -> {:duplicate_output, name, :return}
      unsupported -> {:unsupported_output, name, field(unsupported, :kind)}
      not non_blank?(destination_name) -> {:missing_destination, name, destination_name}
      not valid_ontology?(ontology) -> {:invalid_ontology, name, ontology}
      return_output && not valid_return_handler?(handler) ->
        {:invalid_return_handler, name, handler}

      true -> nil
    end
  end

  defp valid_return_handler?(handler) do
    is_atom(handler) and Code.ensure_loaded?(handler) and
      Gralkor.Artefact.ReturnHandler in
        Keyword.get(handler.module_info(:attributes), :behaviour, []) and
      function_exported?(handler, :return, 3)
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

  defp named_lens_error(_reflection_name, triggers) when not is_list(triggers), do: nil

  defp named_lens_error(reflection_name, triggers) do
    triggers
    |> Enum.flat_map(fn
      {:lens_ingestion, lenses} when is_list(lenses) -> lenses
      _ -> []
    end)
    |> Enum.find_value(fn lens_name ->
      case resolve_lens(lens_name) do
        {:ok, %Gralkor.Lens{}} -> nil
        {:ok, _lens} -> {:incompatible_lens, reflection_name, lens_name}
        :error -> {:unknown_lens, reflection_name, lens_name}
      end
    end)
  end

  defp resolve_lens(lens_name) do
    {:ok, apply(Gralkor.Client, :lens!, [lens_name])}
  rescue
    ArgumentError -> :error
  end

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
