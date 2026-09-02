defmodule Gralkor.Reflection.Runner do
  @moduledoc "Runs a repository-defined Chain of Thought as an ordered, tool-capable inference sequence."

  alias Gralkor.Client
  alias Gralkor.Reflection
  alias Gralkor.Reflection.Artefact
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Search

  @packaged_generalisation_path "priv/reflections/generalisations.yaml"

  def run(%Reflection{} = reflection, ingestion, opts \\ []) when is_map(ingestion) do
    inference = Keyword.get(opts, :inference, &default_inference/1)
    tool_executor = Keyword.get(opts, :tool_executor, &default_tool_executor/2)
    tools = Keyword.get(opts, :tools, [])
    tool_context = Keyword.get(opts, :tool_context, %{})

    case related_memory(reflection, ingestion) do
      {:ok, stored_information} ->
        run_steps(
          reflection,
          ingestion,
          inference,
          tool_executor,
          tools,
          tool_context,
          stored_information,
          opts
        )

      {:error, reason} ->
        {:error, %{reflection: reflection.name, reason: {:related_memory_search, reason}}}
    end
  end

  defp run_steps(
         reflection,
         ingestion,
         inference,
         tool_executor,
         tools,
         tool_context,
         stored_information,
         opts
       ) do
    result =
      Enum.reduce_while(reflection.chain_of_thought.steps, {:ok, %{}}, fn step, {:ok, outputs} ->
        directions = interpolate(step.directions, outputs)

        request = %{
          reflection: reflection.name,
          operator_id: Map.get(ingestion, :operator_id) || Map.get(ingestion, "operator_id"),
          invocation_id: field(ingestion, :id),
          trigger: field(ingestion, :trigger) || :ingestion,
          trigger_context: field(ingestion, :trigger_context) || %{},
          representations: representations(ingestion),
          step: %{label: step.label, directions: directions},
          directions: directions,
          output_schema: step.output,
          stored_information: stored_information,
          tools: tools,
          tool_context: tool_context,
          tool_results: []
        }

        final_step? = step == List.last(reflection.chain_of_thought.steps)

        case infer_step(request, inference, tool_executor) do
          {:ok, output} ->
            case validate_output(output, step.output) do
              {:ok, normalized} ->
                {:cont, {:ok, Map.merge(outputs, normalized)}}

              {:error, {:missing_output, _}} when final_step? ->
                {:halt, {:error, %{reflection: reflection.name, reason: :missing_artefact}}}

              {:error, reason} ->
                {:halt, failure(reflection, step, reason)}
            end

          {:error, reason} ->
            {:halt, failure(reflection, step, reason)}
        end
      end)

    case result do
      {:ok, outputs} ->
        case List.last(reflection.chain_of_thought.steps) do
          nil ->
            {:error, %{reflection: reflection.name, reason: :missing_artefact}}

          final ->
            build_artefact(reflection, outputs, final, opts)
        end

      {:error, _} = error ->
        error
    end
  end

  defp related_memory(%Reflection{} = reflection, ingestion) do
    if packaged_generalisation?(reflection) do
      search_related_memory(ingestion)
    else
      {:ok, []}
    end
  end

  defp search_related_memory(ingestion) do
    representations = representations(ingestion)

    query =
      representations
      |> Enum.map(&field(&1, :content))
      |> Enum.map(&render_value/1)
      |> Enum.join("\n")

    Client.search(%Search{
      operator_id: field(ingestion, :operator_id),
      query: query,
      result_type: :episodes
    })
  end

  defp build_artefact(reflection, outputs, final, opts) do
    payload = outputs |> Map.take(Map.keys(final.output)) |> normalize_payload(reflection)

    if map_size(payload) == 0 do
      {:error, %{reflection: reflection.name, reason: :missing_artefact}}
    else
      artefact =
        case Keyword.get(opts, :artefact_id) do
          nil -> Artefact.new(reflection.name, payload)
          id -> Artefact.new(id, reflection.name, payload)
        end

      {:ok, artefact}
    end
  end

  defp normalize_payload(payload, %Reflection{} = reflection) do
    if packaged_generalisation?(reflection) do
      Map.update!(payload, "generalisations", fn generalisations ->
        Enum.map(generalisations, &normalize_generalisation/1)
      end)
    else
      payload
    end
  end

  defp packaged_generalisation?(%Reflection{
         name: "generalisations",
         chain_of_thought: %ChainOfThought{path: path}
       }) do
    path == Application.app_dir(:jido_gralkor, @packaged_generalisation_path)
  end

  defp packaged_generalisation?(%Reflection{}), do: false

  defp normalize_generalisation(generalisation) do
    snapshots =
      generalisation
      |> field(:evolves_from)
      |> Enum.map(fn item ->
        %{"content" => field(item, :content), "level" => field(item, :level)}
      end)

    level =
      case snapshots do
        [] -> 1
        items -> items |> Enum.map(& &1["level"]) |> Enum.max() |> Kernel.+(1)
      end

    %{
      "content" => field(generalisation, :content),
      "level" => level,
      "evolves_from" => snapshots
    }
  end

  defp infer_step(request, inference, tool_executor) do
    case inference.(request) do
      {:ok, %{tool_calls: calls}} when is_list(calls) and calls != [] ->
        results = Enum.map(calls, &execute_tool(&1, request, tool_executor))

        infer_step(
          %{request | tool_results: request.tool_results ++ results},
          inference,
          tool_executor
        )

      {:tool_calls, calls} when is_list(calls) and calls != [] ->
        results = Enum.map(calls, &execute_tool(&1, request, tool_executor))

        infer_step(
          %{request | tool_results: request.tool_results ++ results},
          inference,
          tool_executor
        )

      {:ok, %{output: output}} when is_map(output) ->
        {:ok, output}

      {:ok, output} when is_map(output) ->
        {:ok, output}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_inference_response, other}}
    end
  end

  defp execute_tool(call, request, executor) do
    result =
      executor.(call, %{
        reflection: request.reflection,
        operator_id: request.operator_id,
        tools: request.tools,
        tool_context: request.tool_context
      })

    %{call: call, result: result}
  end

  defp failure(reflection, step, reason),
    do: {:error, %{reflection: reflection.name, step: step.label, reason: reason}}

  defp interpolate(directions, outputs) do
    Regex.replace(~r/\{\{\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}/, directions, fn _, name ->
      outputs |> Map.fetch!(name) |> render_value()
    end)
  end

  defp render_value(value) when is_binary(value), do: value
  defp render_value(value), do: Jason.encode!(value)

  defp validate_output(output, schema) do
    normalized = Map.new(output, fn {key, value} -> {to_string(key), value} end)
    expected = Map.keys(schema) |> MapSet.new()
    actual = Map.keys(normalized) |> MapSet.new()

    cond do
      missing = expected |> MapSet.difference(actual) |> Enum.at(0) ->
        {:error, {:missing_output, missing}}

      extra = actual |> MapSet.difference(expected) |> Enum.at(0) ->
        {:error, {:unexpected_output, extra}}

      mismatch =
          Enum.find(schema, fn {key, type} ->
            not ChainOfThought.matches_type?(normalized[key], type)
          end) ->
        {key, type} = mismatch
        {:error, {:output_type_mismatch, key, type}}

      true ->
        {:ok, normalized}
    end
  end

  defp representations(ingestion),
    do: Map.get(ingestion, :representations) || Map.get(ingestion, "representations") || []

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  # Jido.AI's standalone tool action owns the provider conversation and executes
  # every configured action until a final answer is produced. The final answer
  # is JSON because the step prompt includes its exact declared contract.
  def default_inference(request), do: default_inference(request, &Jido.Exec.run/3)

  @doc false
  def default_inference(request, call_with_tools) when is_function(call_with_tools, 3) do
    prompt = """
    #{request.directions}

    Lensed representations available to this Reflection step:
    #{Jason.encode!(serializable_representations(request))}

    Related stored information available to this Reflection step:
    #{Jason.encode!(request.stored_information)}

    Return only one JSON object satisfying this exact output contract:
    #{Jason.encode!(request.output_schema)}

    The quoted contract values are type declarations, not literal output
    values. Emit actual JSON values of those types. In particular, an object
    declaration such as "{ field: string }" requires a nested JSON object,
    and an Array<...> declaration requires a JSON array; do not quote either.
    """

    model = Gralkor.Config.llm_model()
    model_spec = "#{model.provider}:#{model.id}"

    context =
      request.tool_context
      |> Map.put_new(:operator_id, request.operator_id)
      |> Map.put(:tools, request.tools)

    case call_with_tools.(
           Jido.AI.Actions.ToolCalling.CallWithTools,
           %{prompt: prompt, auto_execute: true, model: model_spec},
           context
         ) do
      {:ok, %{type: :error, reason: reason}} -> {:error, reason}
      {:ok, result} -> decode_final_output(result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp serializable_representations(request) do
    request
    |> Map.get(:representations, [])
    |> Enum.map(fn representation ->
      Map.take(representation, [:id, :lens, :content, :result])
    end)
  end

  defp decode_final_output(result) do
    text = Map.get(result, :text) || Map.get(result, :content) || Map.get(result, "text")

    case Jason.decode(text || "") do
      {:ok, output} when is_map(output) -> {:ok, %{output: output}}
      {:ok, other} -> {:error, {:invalid_structured_output, other}}
      {:error, reason} -> {:error, {:invalid_structured_output, reason}}
    end
  end

  defp default_tool_executor(call, context) do
    name = field(call, :name)
    args = field(call, :arguments) || %{}
    tools = context |> Map.get(:tools, %{}) |> Jido.AI.ToolAdapter.to_action_map()

    case Map.get(tools, name) do
      nil -> {:error, {:unknown_tool, name}}
      module -> Jido.Exec.run(module, args, Map.get(context, :tool_context, %{}))
    end
  end
end
