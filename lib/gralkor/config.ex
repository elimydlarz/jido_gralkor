defmodule Gralkor.Config do
  @moduledoc """
  Configuration for the embedded Gralkor runtime.

  Two operator-facing knobs decide what `:jido_gralkor` does at boot:

    * The FalkorDB connection — either embedded (`falkordblite` spawns a local
      `redis-server` child under a directory chosen by `GRALKOR_DATA_DIR`) or
      remote (network `host:port` plus optional credentials, set via the
      `:jido_gralkor, :falkordb` application env). Remote wins when both are
      configured. See `falkordb_spec/0`.
    * The LLM and embedder models — set via the `GRALKOR_LLM_MODEL` and
      `GRALKOR_EMBEDDER_MODEL` env vars in `"provider:model"` form (operator
      contract). `llm_model/0` and `embedder_model/0` return them as
      `%{provider: atom(), id: String.t()}` maps — the inline-map shape
      `ReqLLM.model/1` accepts without a catalog lookup (no "unverified model"
      `IO.warn` when the model id is newer than the LLMDB snapshot bundled
      with `req_llm`).
  """

  # Defaults match server-side gralkor/server/main.py — both stacks pick the
  # same model so consumers see identical output.
  @default_llm_model %{provider: :google, id: "gemini-3.1-flash-lite"}
  @default_embedder_model %{provider: :google, id: "gemini-embedding-2-preview"}

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

    unless is_binary(host) and host != "" do
      raise ArgumentError,
            ":jido_gralkor, :falkordb requires :host (non-blank string); got #{inspect(host)}"
    end

    unless is_integer(port) and port > 0 do
      raise ArgumentError,
            ":jido_gralkor, :falkordb requires :port (positive integer); got #{inspect(port)}"
    end

    kw
  end

  @spec llm_model() :: model_spec()
  def llm_model, do: resolve_model_env("GRALKOR_LLM_MODEL", @default_llm_model)

  @spec embedder_model() :: model_spec()
  def embedder_model, do: resolve_model_env("GRALKOR_EMBEDDER_MODEL", @default_embedder_model)

  defp resolve_model_env(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      m -> parse_model_env!(var, m)
    end
  end

  defp parse_model_env!(var, value) do
    case String.split(value, ":", parts: 2) do
      [provider, id] when provider != "" and id != "" ->
        %{provider: String.to_atom(provider), id: id}

      _ ->
        raise ArgumentError,
              "expected #{var} in the form \"provider:model\"; got #{inspect(value)}"
    end
  end
end
