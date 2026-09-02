defmodule Gralkor.Reflection.Runner do
  @moduledoc "Runs a repository-defined Chain of Thought as an ordered, tool-capable inference sequence."

  alias Gralkor.Client
  alias Gralkor.Artefact
  alias Gralkor.Reflection
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
          invocation_context: field(ingestion, :invocation_context) || %{},
          representations: representations(ingestion),
          step: %{label: step.label, directions: directions},
          directions: directions,
          output_schema: step.output,
          stored_information: stored_information,
          tools: tools,
          tool_context: tool_context,
          tool_results: []
        }

        request =
          if packaged_generalisation?(reflection) do
            Map.put(
              request,
              :eligible_generalisation_lineage,
              eligible_generalisation_lineage(stored_information)
            )
          else
            request
          end

        final_step? = step == List.last(reflection.chain_of_thought.steps)

        case infer_step(request, inference, tool_executor) do
          {:ok, output} ->
            case validate_output(output, step.output) do
              {:ok, normalized} ->
                case validate_generalisation_lineage(
                       reflection,
                       step,
                       normalized,
                       stored_information
                     ) do
                  :ok ->
                    {:cont, {:ok, Map.merge(outputs, normalized)}}

                  {:error, reason} ->
                    {:halt, failure(reflection, step, reason)}
                end

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
            build_artefact(reflection, ingestion, outputs, final, opts)
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

  defp build_artefact(reflection, ingestion, outputs, final, opts) do
    payload = artefact_payload(reflection, outputs, final)

    if map_size(payload) == 0 do
      {:error, %{reflection: reflection.name, reason: :missing_artefact}}
    else
      id =
        Keyword.get_lazy(opts, :artefact_id, fn ->
          Artefact.id_for(
            field(ingestion, :operator_id),
            field(ingestion, :id),
            reflection.name
          )
        end)

      {:ok, Artefact.new(id, payload)}
    end
  end

  defp artefact_payload(%Reflection{} = reflection, outputs, final) do
    if packaged_generalisation?(reflection) do
      %{
        "generalisations" =>
          outputs
          |> Map.fetch!("evolutions")
          |> Enum.map(&normalize_generalisation/1)
      }
    else
      Map.take(outputs, Map.keys(final.output))
    end
  end

  defp packaged_generalisation?(%Reflection{
         name: "generalisations",
         chain_of_thought: %ChainOfThought{path: path}
       }) do
    path == Application.app_dir(:jido_gralkor, @packaged_generalisation_path)
  end

  defp packaged_generalisation?(%Reflection{}), do: false

  defp validate_generalisation_lineage(
         %Reflection{} = reflection,
         %{label: "evolve-generalisations"},
         %{"evolutions" => evolutions},
         stored_information
       ) do
    if packaged_generalisation?(reflection) do
      allowed =
        stored_information
        |> eligible_generalisation_lineage()
        |> Enum.map(&lineage_identity/1)
        |> MapSet.new()

      evolutions
      |> Enum.flat_map(&field(&1, :evolves_from))
      |> Enum.reduce_while(:ok, fn snapshot, :ok ->
        normalized = lineage_snapshot(snapshot)

        if MapSet.member?(allowed, lineage_identity(normalized)) do
          {:cont, :ok}
        else
          {:halt, {:error, {:invalid_generalisation_lineage, normalized}}}
        end
      end)
    else
      :ok
    end
  end

  defp validate_generalisation_lineage(_reflection, _step, _output, _stored_information),
    do: :ok

  defp eligible_generalisation_lineage(stored_information) do
    stored_information
    |> Enum.flat_map(&prior_generalisations/1)
    |> Enum.map(&lineage_snapshot/1)
    |> Enum.filter(&valid_lineage_snapshot?/1)
    |> Enum.uniq()
  end

  defp prior_generalisations(stored_information) do
    episode = field(stored_information, :episode)

    if is_map(episode) and field(episode, :reflection) == "generalisations" do
      decode_generalisation_artefact(field(episode, :content))
    else
      []
    end
  end

  defp decode_generalisation_artefact(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"id" => id, "payload" => %{"generalisations" => generalisations}} = artefact}
      when map_size(artefact) == 2 and is_binary(id) and is_list(generalisations) ->
        generalisations

      _ ->
        []
    end
  end

  defp decode_generalisation_artefact(_content), do: []

  defp lineage_snapshot(item) do
    %{"content" => field(item, :content), "level" => field(item, :level)}
  end

  defp lineage_identity(%{"content" => content, "level" => level}), do: {content, level}

  defp valid_lineage_snapshot?(%{"content" => content, "level" => level}) do
    is_binary(content) and String.trim(content) != "" and is_integer(level) and level > 0
  end

  defp normalize_generalisation(generalisation) do
    snapshots =
      generalisation
      |> field(:evolves_from)
      |> Enum.map(&lineage_snapshot/1)

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

    #{eligible_generalisation_lineage_prompt(request)}

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

  defp eligible_generalisation_lineage_prompt(%{
         eligible_generalisation_lineage: snapshots
       }) do
    "Eligible prior-generalisation lineage snapshots:\n#{Jason.encode!(snapshots)}"
  end

  defp eligible_generalisation_lineage_prompt(_request), do: ""

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
