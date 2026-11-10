defmodule Gralkor.Reflection.Runner do
  @moduledoc "Runs a repository-defined Chain of Thought as an ordered, tool-capable inference sequence."

  alias Gralkor.Artefact
  alias Gralkor.Reflection
  alias Gralkor.Reflection.ChainOfThought

  @max_output_tokens 32_768
  @dropped_call_retry_delays_ms [1_000, 2_000, 4_000]

  def run(%Reflection{} = reflection, ingestion, opts \\ []) when is_map(ingestion) do
    inference =
      Keyword.get_lazy(opts, :inference, fn ->
        built_in = Keyword.take(opts, [:model_resolver, :observer])

        run_step = if built_in[:observer], do: &observed_react/3, else: &react/3

        fn request -> default_inference(request, run_step, built_in) end
      end)

    tool_executor = Keyword.get(opts, :tool_executor, &default_tool_executor/2)
    tools = Keyword.get(opts, :tools, [])
    tool_context = Keyword.get(opts, :tool_context, %{})

    run_steps(reflection, ingestion, inference, tool_executor, tools, tool_context, opts)
  end

  defp run_steps(reflection, ingestion, inference, tool_executor, tools, tool_context, opts) do
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
    do: default_inference(request, &react/3, [])

  @doc false
  def default_inference(request, run_step) when is_function(run_step, 3),
    do: default_inference(request, run_step, [])

  def default_inference(request, run_step, opts)
      when is_function(run_step, 3) and is_list(opts) do
    prompt = """
    #{request.directions}

    Lensed representations available to this Reflection step:
    #{Jason.encode!(serializable_representations(request))}

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

    config = %{
      model: model_spec,
      tools: request.tools,
      streaming: false,
      max_iterations: 10,
      max_tokens: @max_output_tokens,
      temperature: 0.7,
      tool_concurrency: 1,
      tool_max_retries: 0,
      tool_timeout_ms: 30_000
    }

    react_opts = [context: context] ++ event_observer(opts)

    case run_until_settled(run_step, prompt, config, react_opts, @dropped_call_retry_delays_ms) do
      %{termination_reason: :final_answer, result: result} -> decode_final_output(%{text: result})
      %{termination_reason: :failed, result: reason} -> {:error, reason}
      %{termination_reason: termination_reason} -> {:error, termination_reason}
    end
  end

  defp run_until_settled(run_step, input, config, react_opts, delays) do
    case {run_step.(input, config, react_opts), delays} do
      {%{termination_reason: :failed, result: reason} = run, [delay | later_delays]} ->
        if dropped_connection?(reason) do
          Application.get_env(:jido_gralkor, :reflection_retry_sleep, &Process.sleep/1).(delay)
          run_until_settled(run_step, resume_point(run, input), config, react_opts, later_delays)
        else
          run
        end

      {run, _delays} ->
        run
    end
  end

  defp dropped_connection?(%ReqLLM.Error.API.Request{
         status: nil,
         cause: %Req.TransportError{reason: reason}
       }),
       do: reason in [:closed, :timeout, :econnrefused]

  defp dropped_connection?(_reason), do: false

  defp resume_point(run, input) do
    run.trace
    |> Enum.reverse()
    |> Enum.find_value(input, fn
      %{kind: :checkpoint, data: %{reason: reason, token: token}} when reason != :terminal ->
        {:checkpoint, token}

      _event ->
        nil
    end)
  end

  @doc false
  def react(input, config, opts) do
    input
    |> react_events(config, opts)
    |> Jido.AI.Reasoning.ReAct.collect_stream()
  end

  defp react_events({:checkpoint, token}, config, opts) do
    {:ok, %{events: events}} = Jido.AI.Reasoning.ReAct.continue(token, config, opts)
    events
  end

  defp react_events(prompt, config, opts),
    do: Jido.AI.Reasoning.ReAct.stream(prompt, config, opts)

  @doc false
  def observed_react(input, config, opts) do
    {on_event, opts} = Keyword.pop!(opts, :on_event)

    input
    |> react_events(config, opts)
    |> Stream.each(on_event)
    |> Jido.AI.Reasoning.ReAct.collect_stream()
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
