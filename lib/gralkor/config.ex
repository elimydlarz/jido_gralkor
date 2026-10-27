defmodule Gralkor.Config do
  @moduledoc """
  Configuration for the embedded Gralkor runtime.

  Three operator-facing knobs decide what `:jido_gralkor` does at boot:

    * The FalkorDB connection — either embedded (`falkordblite` spawns a local
      `redis-server` child under a directory chosen by `GRALKOR_DATA_DIR`) or
      remote (network `host:port` plus optional credentials, set via the
      `:jido_gralkor, :falkordb` application env). Remote wins when both are
      configured. See `falkordb_spec/0`.
    * The embedded FalkorDB socket read timeout — configured in milliseconds as
      `:embedded_falkordb_socket_timeout_ms`, defaulting to 60 seconds. It is
      validated only when the embedded backend starts.
    * The LLM and embedder models — set via the `GRALKOR_LLM_MODEL` and
      `GRALKOR_EMBEDDER_MODEL` env vars in `"provider:model"` form (operator
      contract). `llm_model/0` and `embedder_model/0` return them as
      `%{provider: atom(), id: String.t()}` maps — the inline-map shape
      `ReqLLM.model/1` accepts without a catalog lookup (no "unverified model"
      `IO.warn` when the model id is newer than the LLMDB snapshot bundled
      with `req_llm`). Parsing is provider-agnostic, but the native
      `Gralkor.GraphitiPool` boundary accepts OpenAI and Google LLM and embedder
      specs; explicit ReqLLM-only calls may use other providers.
    * Optional inference settings, each read from its own env var. Unset or
      blank means the graph library's own default (Google embedders keep one
      input per request):
      `GRALKOR_RERANKER_MODEL` (`reranker_model/0`), `GRALKOR_LLM_ROUTES`
      (`llm_routes/0`), the LLM tuning variables `GRALKOR_LLM_TEMPERATURE`,
      `GRALKOR_LLM_MAX_TOKENS`, `GRALKOR_LLM_REASONING`,
      `GRALKOR_LLM_VERBOSITY`, and `GRALKOR_LLM_THINKING_BUDGET`
      (`llm_tuning/0`), plus `GRALKOR_EMBEDDER_DIMENSION`
      (`embedder_dimension/0`) and `GRALKOR_EMBEDDER_BATCH_SIZE`
      (`embedder_batch_size/0`). Parsing is provider-agnostic; whether a
      provider accepts a setting is decided where the inference clients are
      built.
  """

  @default_llm_model %{provider: :google, id: "gemini-3.1-flash-lite"}
  @default_embedder_model %{provider: :google, id: "gemini-embedding-2-preview"}
  @default_embedded_falkordb_socket_timeout_ms 60_000

  # Graphiti 0.31.2's prompt groups and their prompts
  # (graphiti_core/prompts/names.py). A route key names a whole group or one
  # group-qualified prompt.
  @prompt_groups %{
    "extract_nodes" => ~w(extract_message extract_json extract_text classify_nodes
      extract_attributes extract_summary extract_summaries_batch
      extract_entity_summaries_from_episodes),
    "dedupe_nodes" => ~w(node node_list nodes),
    "extract_edges" => ~w(edge extract_attributes extract_timestamps extract_timestamps_batch),
    "extract_nodes_and_edges" => ~w(extract_message),
    "dedupe_edges" => ~w(resolve_edge),
    "summarize_nodes" => ~w(summarize_pair summarize_context summary_description),
    "summarize_sagas" => ~w(summarize_saga),
    "eval" => ~w(query_expansion qa_prompt eval_prompt eval_add_episode_results)
  }
  @route_keys @prompt_groups
              |> Enum.flat_map(fn {group, prompts} ->
                [group | Enum.map(prompts, &"#{group}.#{&1}")]
              end)
              |> Enum.sort()

  # Each LLM tuning setting, its env var, and the type it parses as. A thinking
  # budget is any integer of at least -1: 0 turns thinking off and -1 asks for
  # a dynamic budget (Gemini's convention).
  @llm_tuning [
    temperature: {"GRALKOR_LLM_TEMPERATURE", :number},
    max_tokens: {"GRALKOR_LLM_MAX_TOKENS", :positive_integer},
    reasoning: {"GRALKOR_LLM_REASONING", :string},
    verbosity: {"GRALKOR_LLM_VERBOSITY", :string},
    thinking_budget: {"GRALKOR_LLM_THINKING_BUDGET", :thinking_budget}
  ]
  @route_tuning Map.new(@llm_tuning, fn {setting, {_var, type}} ->
                  {Atom.to_string(setting), {setting, type}}
                end)

  @typedoc """
  Resolved model spec — the inline-map shape `ReqLLM.model/1` accepts directly.
  """
  @type model_spec :: %{provider: atom(), id: String.t()}

  @typedoc """
  Resolved FalkorDB selection. `:remote` carries the validated keyword list
  the operator supplied; `:embedded` carries the expanded data directory.
  """
  @type falkordb_spec :: {:remote, keyword()} | {:embedded, String.t()}

  @doc """
  Resolve the FalkorDB connection spec from configuration. Returns `nil`
  when neither knob is set so the supervisor can run with no children.

  Remote wins over embedded when both are present.
  """
  @spec falkordb_spec() :: falkordb_spec() | nil
  def falkordb_spec do
    case Application.get_env(:jido_gralkor, :falkordb) do
      nil ->
        embedded_spec()

      kw ->
        {:remote, validate_falkordb!(kw)}
    end
  end

  defp embedded_spec do
    case System.get_env("GRALKOR_DATA_DIR") do
      nil -> nil
      dir -> if String.trim(dir) == "", do: nil, else: {:embedded, Path.expand(dir)}
    end
  end

  @doc """
  Validate a remote FalkorDB keyword spec. Raises `ArgumentError` with a
  pointed message if the shape is wrong; returns the keyword list unchanged
  on success.
  """
  @spec validate_falkordb!(any()) :: keyword()
  def validate_falkordb!(kw) do
    unless Keyword.keyword?(kw) do
      raise ArgumentError,
            "expected :jido_gralkor, :falkordb to be a keyword list with :host and :port; got #{inspect(kw)}"
    end

    host = Keyword.get(kw, :host)
    port = Keyword.get(kw, :port)

    unless is_binary(host) and String.trim(host) != "" do
      raise ArgumentError,
            ":jido_gralkor, :falkordb requires :host (non-blank string); got #{inspect(host)}"
    end

    unless is_integer(port) and port > 0 do
      raise ArgumentError,
            ":jido_gralkor, :falkordb requires :port (positive integer); got #{inspect(port)}"
    end

    kw
  end

  @doc """
  Resolve the embedded FalkorDB socket read timeout in milliseconds.
  """
  @spec embedded_falkordb_socket_timeout_ms() :: pos_integer()
  def embedded_falkordb_socket_timeout_ms do
    :jido_gralkor
    |> Application.get_env(
      :embedded_falkordb_socket_timeout_ms,
      @default_embedded_falkordb_socket_timeout_ms
    )
    |> validate_embedded_falkordb_socket_timeout_ms!()
  end

  @doc false
  @spec validate_embedded_falkordb_socket_timeout_ms!(term()) :: pos_integer()
  def validate_embedded_falkordb_socket_timeout_ms!(value)
      when is_integer(value) and value > 0,
      do: value

  def validate_embedded_falkordb_socket_timeout_ms!(value) do
    raise ArgumentError,
          ":embedded_falkordb_socket_timeout_ms must be a positive integer, got #{inspect(value)}"
  end

  @spec llm_model() :: model_spec()
  def llm_model, do: resolve_model_env("GRALKOR_LLM_MODEL", @default_llm_model)

  @spec embedder_model() :: model_spec()
  def embedder_model, do: resolve_model_env("GRALKOR_EMBEDDER_MODEL", @default_embedder_model)

  @doc """
  The reranker's model spec from `GRALKOR_RERANKER_MODEL`, or `nil` when unset
  or blank — the reranker then follows the LLM's provider with the graph
  library's default reranker model.
  """
  @spec reranker_model() :: model_spec() | nil
  def reranker_model, do: resolve_model_env("GRALKOR_RERANKER_MODEL", nil)

  @typedoc "One prompt route: the model it runs on and the tuning it sets."
  @type llm_route :: %{model: model_spec(), tuning: %{optional(atom()) => term()}}

  @doc """
  The LLM routes from `GRALKOR_LLM_ROUTES`, a JSON object keyed by a Graphiti
  prompt group (`"extract_edges"`) or a group-qualified prompt
  (`"extract_edges.extract_timestamps"`). Each value carries a required
  `"model"` in `"provider:model"` form and optional tuning fields
  (`max_tokens`, `temperature`, `reasoning`, `verbosity`, `thinking_budget`).
  Unset or blank returns no routes.
  """
  @spec llm_routes() :: %{String.t() => llm_route()}
  def llm_routes do
    var = "GRALKOR_LLM_ROUTES"

    case blank_to_nil(System.get_env(var)) do
      nil ->
        %{}

      value ->
        case Jason.decode(value) do
          {:ok, routes} when is_map(routes) ->
            Map.new(routes, fn {key, route} -> {key, parse_route!(key, route)} end)

          _ ->
            raise ArgumentError, "expected #{var} to be a JSON object; got #{inspect(value)}"
        end
    end
  end

  @doc """
  The tuning configured for the `GRALKOR_LLM_MODEL` client: only the settings
  whose env var is set and non-blank, each parsed as its type.
  """
  @spec llm_tuning() :: %{optional(atom()) => term()}
  def llm_tuning do
    for {setting, {var, type}} <- @llm_tuning,
        value = blank_to_nil(System.get_env(var)),
        value != nil,
        into: %{},
        do: {setting, parse_env!(var, String.trim(value), type)}
  end

  @doc "The embedding dimension from `GRALKOR_EMBEDDER_DIMENSION`, or `nil`."
  @spec embedder_dimension() :: pos_integer() | nil
  def embedder_dimension, do: positive_integer_env("GRALKOR_EMBEDDER_DIMENSION")

  @doc "The embedder batch size from `GRALKOR_EMBEDDER_BATCH_SIZE`, or `nil`."
  @spec embedder_batch_size() :: pos_integer() | nil
  def embedder_batch_size, do: positive_integer_env("GRALKOR_EMBEDDER_BATCH_SIZE")

  defp positive_integer_env(var) do
    case blank_to_nil(System.get_env(var)) do
      nil -> nil
      value -> parse_env!(var, String.trim(value), :positive_integer)
    end
  end

  defp parse_env!(var, value, :positive_integer) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> raise ArgumentError, "expected #{var} to be a positive integer; got #{inspect(value)}"
    end
  end

  defp parse_env!(var, value, :thinking_budget) do
    case Integer.parse(value) do
      {integer, ""} when integer >= -1 ->
        integer

      _ ->
        raise ArgumentError,
              "expected #{var} to be an integer of at least -1; got #{inspect(value)}"
    end
  end

  defp parse_env!(var, value, :number) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> raise ArgumentError, "expected #{var} to be a number; got #{inspect(value)}"
    end
  end

  defp parse_env!(_var, value, :string), do: value

  defp parse_route!(key, route) do
    unless key in @route_keys do
      raise ArgumentError,
            "GRALKOR_LLM_ROUTES key #{inspect(key)} names neither a prompt group nor a " <>
              "prompt of that group; accepted: #{Enum.join(@route_keys, ", ")}"
    end

    unless is_map(route) do
      raise ArgumentError,
            "GRALKOR_LLM_ROUTES route #{inspect(key)} must be an object with a \"model\" in " <>
              "the form \"provider:model\"; got #{inspect(route)}"
    end

    {model, fields} = Map.pop(route, "model")

    tuning =
      Map.new(fields, fn {field, value} ->
        case Map.fetch(@route_tuning, field) do
          {:ok, {setting, type}} ->
            {setting, parse_route_tuning!(key, field, value, type)}

          :error ->
            raise ArgumentError,
                  "GRALKOR_LLM_ROUTES route #{inspect(key)} sets #{inspect(field)}, which is " <>
                    "neither \"model\" nor a tuning setting " <>
                    "(#{Enum.join(Map.keys(@route_tuning), ", ")})"
        end
      end)

    %{model: parse_route_model!(key, model), tuning: tuning}
  end

  defp parse_route_model!(key, model) do
    with true <- is_binary(model),
         [provider, id] <- String.split(model, ":", parts: 2),
         provider = String.trim(provider),
         id = String.trim(id),
         true <- provider != "" and id != "" do
      %{provider: String.to_atom(provider), id: id}
    else
      _ ->
        raise ArgumentError,
              "GRALKOR_LLM_ROUTES route #{inspect(key)} requires \"model\" in the form " <>
                "\"provider:model\"; got #{inspect(model)}"
    end
  end

  defp parse_route_tuning!(_key, _field, value, :positive_integer)
       when is_integer(value) and value > 0,
       do: value

  defp parse_route_tuning!(_key, _field, value, :thinking_budget)
       when is_integer(value) and value >= -1,
       do: value

  defp parse_route_tuning!(_key, _field, value, :number) when is_number(value), do: value

  defp parse_route_tuning!(key, field, value, :string) when is_binary(value) do
    case String.trim(value) do
      "" -> invalid_route_tuning!(key, field, value, :string)
      trimmed -> trimmed
    end
  end

  defp parse_route_tuning!(key, field, value, type),
    do: invalid_route_tuning!(key, field, value, type)

  defp invalid_route_tuning!(key, field, value, type) do
    expected =
      case type do
        :positive_integer -> "a positive integer"
        :thinking_budget -> "an integer of at least -1"
        :number -> "a number"
        :string -> "a non-blank string"
      end

    raise ArgumentError,
          "GRALKOR_LLM_ROUTES route #{inspect(key)} requires #{field} to be #{expected}; " <>
            "got #{inspect(value)}"
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp resolve_model_env(var, default) do
    case System.get_env(var) do
      nil -> default
      value -> if String.trim(value) == "", do: default, else: parse_model_env!(var, value)
    end
  end

  defp parse_model_env!(var, value) do
    case String.split(value, ":", parts: 2) do
      [provider, id] ->
        provider = String.trim(provider)
        id = String.trim(id)

        if provider != "" and id != "" do
          %{provider: String.to_atom(provider), id: id}
        else
          invalid_model_env!(var, value)
        end

      _ ->
        invalid_model_env!(var, value)
    end
  end

  defp invalid_model_env!(var, value) do
    raise ArgumentError,
          "expected #{var} in the form \"provider:model\"; got #{inspect(value)}"
  end
end
