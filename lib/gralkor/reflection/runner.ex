defmodule Gralkor.Reflection.Runner do
  @moduledoc "Runs a repository-defined Chain of Thought as an ordered, tool-capable inference sequence."

  alias Gralkor.Client
  alias Gralkor.Artefact
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought
  alias Gralkor.Search
  alias JidoGralkor.MemorySearchPresentation

  def run(%Reflection{} = reflection, ingestion, opts \\ []) when is_map(ingestion) do
    inference =
      Keyword.get_lazy(opts, :inference, fn ->
        built_in = Keyword.take(opts, [:model_resolver, :observer])

        run_step =
          if built_in[:observer], do: &observed_react/3, else: &Jido.AI.Reasoning.ReAct.run/3

        fn request -> default_inference(request, run_step, built_in) end
      end)

    tool_executor = Keyword.get(opts, :tool_executor, &default_tool_executor/2)
    tools = Keyword.get(opts, :tools, [])
    tool_context = Keyword.get(opts, :tool_context, %{})

    case related_memory(reflection, ingestion, opts) do
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
    observer = Keyword.get(opts, :observer, fn _event -> :ok end)

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

        final_step? = step == List.last(reflection.chain_of_thought.steps)

        observer.({:step_started, step.label})

        case infer_step(request, inference, tool_executor) do
          {:ok, output} ->
            case validate_output(output, step.output, Keyword.get(opts, :type_matcher)) do
              {:ok, normalized} ->
                observer.({:step_finished, step.label})
                {:cont, {:ok, Map.merge(outputs, normalized)}}

              {:error, {:missing_output, _}} when final_step? ->
                observer.({:step_failed, step.label})
                {:halt, {:error, %{reflection: reflection.name, reason: :missing_artefact}}}

              {:error, reason} ->
                observer.({:step_failed, step.label})
                {:halt, failure(reflection, step, reason)}
            end

          {:error, reason} ->
            observer.({:step_failed, step.label})
            {:halt, failure(reflection, step, reason)}
        end
      end)

    case result do
      {:ok, outputs} ->
        final = List.last(reflection.chain_of_thought.steps)
        build_artefact(reflection, ingestion, outputs, final, opts)

      {:error, _} = error ->
        error
    end
  end

  defp related_memory(%Reflection{} = reflection, ingestion, opts) do
    if packaged_generalisation?(reflection) do
      search_related_memory(ingestion, opts)
    else
      {:ok, []}
    end
  end

  defp search_related_memory(ingestion, opts) do
    representations = representations(ingestion)

    query =
      representations
      |> Enum.map(&field(&1, :content))
      |> Enum.map(&render_value/1)
      |> Enum.join("\n")

    request = %Search{
      operator_id: field(ingestion, :operator_id),
      query: query,
      destinations: ["generalisations"]
    }

    search = Keyword.get(opts, :related_memory_search, &Client.search/2)
    search.(Keyword.fetch!(opts, :runtime_owner), request)
  end

  defp build_artefact(reflection, ingestion, outputs, final, opts) do
    payload = Map.take(outputs, Map.keys(final.output))

    id =
      derive_artefact_id(
        opts,
        field(ingestion, :operator_id),
        field(ingestion, :id),
        reflection.name
      )

    {:ok, Artefact.new(id, payload)}
  end

  defp packaged_generalisation?(%Reflection{name: "generalisations"}), do: true

  defp packaged_generalisation?(%Reflection{}), do: false

  defp infer_step(request, inference, tool_executor) do
    case inference.(request) do
      {:ok, %{tool_calls: calls}} when is_list(calls) and calls != [] ->
        results = Enum.map(calls, &execute_tool(&1, request, tool_executor))

        infer_step(
          %{request | tool_results: request.tool_results ++ results},
          inference,
          tool_executor
        )

      {:ok, %{output: output}} when is_map(output) ->
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

  defp derive_artefact_id(opts, operator_id, invocation_id, reflection_name) do
    resolver = Keyword.get(opts, :artefact_id_for, &Artefact.id_for/3)
    resolver.(operator_id, invocation_id, reflection_name)
  end

  defp validate_output(output, schema, type_matcher) do
    type_matcher = type_matcher || (&ChainOfThought.matches_type?/2)
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
            not type_matcher.(normalized[key], type)
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

  def default_inference(request),
    do: default_inference(request, &Jido.AI.Reasoning.ReAct.run/3, [])

  @doc false
  def default_inference(request, run_step) when is_function(run_step, 3),
    do: default_inference(request, run_step, [])

  def default_inference(request, run_step, opts)
      when is_function(run_step, 3) and is_list(opts) do
    # Prior memory reads exactly as `memory_search` presents it to an agent.
    stored_information =
      request.stored_information
      |> MemorySearchPresentation.sections()
      |> MemorySearchPresentation.text()

    run_default_inference(request, stored_information, run_step, opts)
  end

  defp run_default_inference(request, stored_information, run_step, opts) do
    prompt = """
    #{request.directions}

    Lensed representations available to this Reflection step:
    #{Jason.encode!(serializable_representations(request))}
    #{stored_section(request.stored_information, stored_information)}
    Return only one JSON object satisfying this exact output contract:
    #{Jason.encode!(request.output_schema)}

    The quoted contract values are type declarations, not literal output
    values. Emit actual JSON values of those types. In particular, an object
    declaration such as "{ field: string }" requires a nested JSON object,
    and an Array<...> declaration requires a JSON array; do not quote either.
    """

    model_resolver = Keyword.get(opts, :model_resolver, &Gralkor.Config.llm_model/0)
    model = model_resolver.()
    model_spec = "#{model.provider}:#{model.id}"

    context = Map.put(request.tool_context, :operator_id, request.operator_id)

    case run_step.(
           prompt,
           %{
             model: model_spec,
             tools: request.tools,
             streaming: false,
             max_iterations: 10,
             temperature: 0.7,
             tool_concurrency: 1,
             tool_max_retries: 0,
             tool_timeout_ms: 30_000
           },
           [context: context] ++ event_observer(opts)
         ) do
      %{termination_reason: :final_answer, result: result} -> decode_final_output(%{text: result})
      %{termination_reason: :failed, result: reason} -> {:error, reason}
      %{termination_reason: termination_reason} -> {:error, termination_reason}
    end
  end

  defp stored_section(results, presented) do
    if Enum.any?(results, &holds_memory?/1) do
      "\nRelated stored information available to this Reflection step:\n#{presented}\n"
    else
      ""
    end
  end

  defp holds_memory?(result),
    do: Enum.any?([:facts, :nodes, :episodes], &(Map.get(result, &1, []) != []))

  @doc false
  def observed_react(prompt, config, opts) do
    {on_event, opts} = Keyword.pop!(opts, :on_event)
    events = prompt |> Jido.AI.Reasoning.ReAct.stream(config, opts) |> Stream.each(on_event)
    {:ok, result} = Jido.AI.Reasoning.ReAct.collect(events, config, opts)
    result
  end

  defp event_observer(opts) do
    case Keyword.fetch(opts, :observer) do
      {:ok, observer} -> [on_event: &tell_tool_event(observer, &1)]
      :error -> []
    end
  end

  defp tell_tool_event(observer, %Jido.AI.Runtime.Event{kind: :tool_started} = event) do
    observer.(
      {:tool_started,
       %{id: event.tool_call_id, name: event.tool_name, arguments: event.data[:arguments]}}
    )
  end

  defp tell_tool_event(observer, %Jido.AI.Runtime.Event{kind: :tool_completed} = event) do
    observer.(
      {:tool_completed,
       %{
         id: event.tool_call_id,
         name: event.tool_name,
         duration_ms: event.data[:duration_ms],
         ok?: succeeded?(event.data[:result])
       }}
    )
  end

  defp tell_tool_event(_observer, _event), do: :ok

  defp succeeded?({:ok, _value}), do: true
  defp succeeded?({:ok, _value, _effects}), do: true
  defp succeeded?(_result), do: false

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
