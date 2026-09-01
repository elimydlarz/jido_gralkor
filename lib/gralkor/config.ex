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
  """

  @default_llm_model %{provider: :google, id: "gemini-3.1-flash-lite"}
  @default_embedder_model %{provider: :google, id: "gemini-embedding-2-preview"}
  @default_embedded_falkordb_socket_timeout_ms 60_000

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
      "" -> nil
      dir -> {:embedded, Path.expand(dir)}
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
