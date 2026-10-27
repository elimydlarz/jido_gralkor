defmodule Gralkor.InferenceProviderSelectionFunctionalTest do
  @moduledoc """
  Application-visible provider selection, driven through the operator's actual
  seam: the `GRALKOR_LLM_MODEL` / `GRALKOR_EMBEDDER_MODEL` environment variables
  and the provider credentials, resolved by `Gralkor.Config` and enforced when
  `Gralkor.GraphitiPool` starts.

  Deterministic — inference client construction is substituted at the system
  boundary, so no provider is ever called. Which provider *would* build each
  client is observed through the pool's own construction spec.

  See `test-trees/functional/inference-provider-selection_TEST_TREES.md`.
  """
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Config
  alias Gralkor.GraphitiPool

  @settings ~w(
    GRALKOR_RERANKER_MODEL GRALKOR_LLM_ROUTES GRALKOR_LLM_TEMPERATURE GRALKOR_LLM_MAX_TOKENS
    GRALKOR_LLM_REASONING GRALKOR_LLM_VERBOSITY GRALKOR_LLM_THINKING_BUDGET
    GRALKOR_EMBEDDER_DIMENSION GRALKOR_EMBEDDER_BATCH_SIZE
  )
  @vars ~w(GRALKOR_LLM_MODEL GRALKOR_EMBEDDER_MODEL GOOGLE_API_KEY OPENAI_API_KEY) ++ @settings

  setup do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    Enum.each(@settings, &System.delete_env/1)
    :ok
  end

  defp configure(llm, embedder) do
    if llm,
      do: System.put_env("GRALKOR_LLM_MODEL", llm),
      else: System.delete_env("GRALKOR_LLM_MODEL")

    if embedder,
      do: System.put_env("GRALKOR_EMBEDDER_MODEL", embedder),
      else: System.delete_env("GRALKOR_EMBEDDER_MODEL")
  end

  defp credentials(google, openai) do
    if google,
      do: System.put_env("GOOGLE_API_KEY", google),
      else: System.delete_env("GOOGLE_API_KEY")

    if openai,
      do: System.put_env("OPENAI_API_KEY", openai),
      else: System.delete_env("OPENAI_API_KEY")
  end

  # The deployment has opted into the native runtime; inference client
  # construction is the substituted boundary. The pool resolves every inference
  # setting from the deployment's environment.
  defp start_memory_runtime(test_pid) do
    GraphitiPool.start_link(
      name: nil,
      table: :"provider_selection_#{System.unique_integer([:positive])}",
      falkordb_spec: {:embedded, "/tmp/never_used"},
      construct_shared_clients: fn spec ->
        send(test_pid, {:constructed, spec})
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      construct_falkor_db: fn _ -> :stub_falkor_db end,
      construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
      initialise_instance: fn _ -> :ok end,
      install_loop_fn: fn -> :ok end,
      warmup: false
    )
  end

  # The real provider clients are constructed — constructing them calls no
  # provider — so what each client was configured with is read back from it.
  defp start_constructed_runtime do
    {:ok, pid} =
      GraphitiPool.start_link(
        name: nil,
        table: :"provider_clients_#{System.unique_integer([:positive])}",
        falkordb_spec: {:embedded, "/tmp/never_used"},
        construct_falkor_db: fn _ -> :stub_falkor_db end,
        construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
        initialise_instance: fn _ -> :ok end,
        install_loop_fn: fn -> :ok end,
        warmup: false
      )

    shared = :sys.get_state(pid).shared
    GenServer.stop(pid)
    shared
  end

  defp python(shared, script) do
    {value, _} =
      Pythonx.eval(script, %{
        "llm" => shared.llm_client,
        "runtime" => Map.get(shared, :llm_runtime),
        "embedder" => shared.embedder,
        "reranker" => shared.cross_encoder
      })

    Pythonx.decode(value)
  end

  describe "when the deployment configures an inference LLM and an embedder" do
    test "then each role takes its own configured provider, accepting OpenAI and Google" do
      credentials("google-key", "openai-key")

      for {llm, embedder} <- [
            {"google:gemini-3.1-flash-lite", "google:gemini-embedding-2-preview"},
            {"openai:gpt-4.1-mini", "openai:text-embedding-3-small"}
          ] do
        configure(llm, embedder)
        {:ok, pid} = start_memory_runtime(self())

        assert_receive {:constructed, spec}
        assert "#{spec.llm.provider}:#{spec.llm.id}" == llm
        assert "#{spec.embedder.provider}:#{spec.embedder.id}" == embedder
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end
    end

    test "and differing role providers construct independent clients and start the memory runtime" do
      credentials("google-key", "openai-key")
      configure("openai:gpt-4.1-mini", "google:gemini-embedding-2-preview")

      {:ok, pid} = start_memory_runtime(self())

      assert_receive {:constructed, spec}
      assert spec.llm.provider == :openai
      assert spec.embedder.provider == :google
      assert spec.cross_encoder.provider == :openai
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "when the deployment configures an inference LLM and an embedder > while the deployment configures no reranker" do
    test "then an OpenAI LLM configures OpenAI reranking with the graph library's default reranker model" do
      credentials("google-key", "openai-key")
      configure("openai:gpt-4.1-mini", "openai:text-embedding-3-small")

      shared = start_constructed_runtime()

      assert python(shared, "type(reranker).__name__") == "OpenAIRerankerClient"
      assert python(shared, "reranker.config.model") == nil
    end

    test "and a Google LLM configures Google reranking with the graph library's default reranker model" do
      credentials("google-key", "openai-key")
      configure("google:gemini-3.1-flash-lite", "google:gemini-embedding-2-preview")

      shared = start_constructed_runtime()

      assert python(shared, "type(reranker).__name__") == "GeminiRerankerClient"
      assert python(shared, "reranker.config.model") == nil
    end
  end

  describe "when the deployment configures an inference LLM and an embedder > while the deployment configures a reranker" do
    test "then reranking takes its own configured provider and model" do
      credentials("google-key", "openai-key")

      for {llm, reranker, client} <- [
            {"openai:gpt-4.1-mini", "google:gemini-2.5-flash-lite", "GeminiRerankerClient"},
            {"google:gemini-3.1-flash-lite", "openai:gpt-4.1-nano", "OpenAIRerankerClient"}
          ] do
        configure(llm, "openai:text-embedding-3-small")
        System.put_env("GRALKOR_RERANKER_MODEL", reranker)

        shared = start_constructed_runtime()

        assert python(shared, "type(reranker).__name__") == client

        assert python(shared, "reranker.config.model") ==
                 reranker |> String.split(":") |> List.last()
      end
    end
  end

  describe "when the deployment configures an inference LLM and an embedder > while the deployment configures LLM routes" do
    setup do
      credentials("google-key", "openai-key")
      configure("openai:gpt-5.4-mini", "openai:text-embedding-3-small")

      System.put_env(
        "GRALKOR_LLM_ROUTES",
        Jason.encode!(%{
          "extract_edges" => %{"model" => "google:gemini-3-flash"},
          "dedupe_nodes.node" => %{"model" => "openai:gpt-5.4-nano"}
        })
      )

      %{shared: start_constructed_runtime()}
    end

    test "then each routed prompt runs on its route's provider and model", %{shared: shared} do
      for {prompt, model, client} <- [
            {"extract_edges.edge", "gemini-3-flash", "GeminiClient"},
            {"extract_edges.extract_timestamps", "gemini-3-flash", "GeminiClient"},
            {"dedupe_nodes.node", "gpt-5.4-nano", "OpenAIClient"}
          ] do
        assert python(shared, "runtime.resolve_model('#{prompt}').id") == model

        assert python(
                 shared,
                 "type(runtime.resolve_model('#{prompt}').transport.client).__name__"
               ) ==
                 client
      end
    end

    test "and each unrouted prompt runs on the configured LLM", %{shared: shared} do
      for prompt <- [
            "dedupe_nodes.nodes",
            "summarize_nodes.summarize_pair",
            "extract_nodes.extract_text"
          ] do
        assert python(shared, "runtime.resolve_model('#{prompt}').id") == "gpt-5.4-mini"

        assert python(
                 shared,
                 "type(runtime.resolve_model('#{prompt}').transport.client).__name__"
               ) ==
                 "OpenAIClient"
      end
    end
  end

  describe "when the deployment configures an inference LLM and an embedder > while the deployment configures no LLM routes" do
    test "then the graph library chooses the model for its small-model prompts" do
      credentials("google-key", "openai-key")

      for {llm, client_module} <- [
            {"openai:gpt-5.4-mini", "openai_base_client"},
            {"google:gemini-3.1-flash-lite", "gemini_client"}
          ] do
        configure(llm, "openai:text-embedding-3-small")

        shared = start_constructed_runtime()

        assert python(shared, "runtime") == nil

        assert python(shared, """
               from graphiti_core.llm_client.config import ModelSize
               from graphiti_core.llm_client.#{client_module} import DEFAULT_SMALL_MODEL
               llm._get_model_for_size(ModelSize.small) == DEFAULT_SMALL_MODEL
               """)
      end
    end
  end

  describe "when the deployment configures an inference LLM and an embedder > while the deployment configures LLM tuning or embedder settings" do
    test "then the memory runtime's clients receive them" do
      credentials("google-key", "openai-key")
      configure("openai:gpt-5.4-mini", "google:gemini-embedding-2-preview")
      System.put_env("GRALKOR_LLM_TEMPERATURE", "0.2")
      System.put_env("GRALKOR_LLM_MAX_TOKENS", "4096")
      System.put_env("GRALKOR_LLM_REASONING", "low")
      System.put_env("GRALKOR_LLM_VERBOSITY", "medium")
      System.put_env("GRALKOR_EMBEDDER_DIMENSION", "768")
      System.put_env("GRALKOR_EMBEDDER_BATCH_SIZE", "8")

      shared = start_constructed_runtime()

      assert python(shared, "[llm.temperature, llm.max_tokens, llm.reasoning, llm.verbosity]") ==
               [0.2, 4096, "low", "medium"]

      assert python(shared, "[embedder.config.embedding_dim, embedder.batch_size]") == [768, 8]

      Enum.each(~w(GRALKOR_LLM_REASONING GRALKOR_LLM_VERBOSITY), &System.delete_env/1)
      configure("google:gemini-3.1-flash-lite", "openai:text-embedding-3-small")
      System.delete_env("GRALKOR_EMBEDDER_BATCH_SIZE")
      System.put_env("GRALKOR_LLM_THINKING_BUDGET", "1024")

      shared = start_constructed_runtime()

      assert python(
               shared,
               "[llm.temperature, llm.max_tokens, llm.thinking_config.thinking_budget]"
             ) ==
               [0.2, 4096, 1024]

      assert python(shared, "embedder.config.embedding_dim") == 768
    end
  end

  describe "when the deployment configures an inference LLM and an embedder > while the deployment configures no LLM tuning or embedder settings" do
    test "then the memory runtime's clients use the graph library's defaults" do
      credentials("google-key", "openai-key")
      configure("openai:gpt-5.4-mini", "openai:text-embedding-3-small")

      shared = start_constructed_runtime()

      assert python(shared, """
             from graphiti_core.embedder.client import EMBEDDING_DIM
             from graphiti_core.llm_client.config import DEFAULT_MAX_TOKENS, DEFAULT_TEMPERATURE
             from graphiti_core.llm_client.openai_base_client import DEFAULT_REASONING, DEFAULT_VERBOSITY
             [
                 llm.temperature == DEFAULT_TEMPERATURE,
                 llm.max_tokens == DEFAULT_MAX_TOKENS,
                 llm.reasoning == DEFAULT_REASONING,
                 llm.verbosity == DEFAULT_VERBOSITY,
                 embedder.config.embedding_dim == EMBEDDING_DIM,
             ]
             """) == [true, true, true, true, true]

      configure("google:gemini-3.1-flash-lite", "google:gemini-embedding-2-preview")

      shared = start_constructed_runtime()

      assert python(shared, """
             from graphiti_core.embedder.client import EMBEDDING_DIM
             from graphiti_core.llm_client.config import DEFAULT_TEMPERATURE
             [
                 llm.temperature == DEFAULT_TEMPERATURE,
                 llm.max_tokens is None,
                 llm.thinking_config is None,
                 embedder.config.embedding_dim == EMBEDDING_DIM,
             ]
             """) == [true, true, true, true]
    end
  end

  describe "where the deployment configures no LLM or embedder override" do
    test "then Google configures both roles and its credential alone starts the memory runtime" do
      configure(nil, nil)
      credentials("google-key", nil)

      {:ok, pid} = start_memory_runtime(self())

      assert_receive {:constructed, spec}
      assert spec.llm.provider == :google
      assert spec.embedder.provider == :google
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "where the deployment configures a blank LLM or embedder override" do
    test "then that role uses its Google default" do
      configure("   ", "openai:text-embedding-3-small")
      assert Config.llm_model() == %{provider: :google, id: "gemini-3.1-flash-lite"}

      configure("openai:gpt-4.1-mini", "   ")

      assert Config.embedder_model() == %{
               provider: :google,
               id: "gemini-embedding-2-preview"
             }
    end
  end

  describe "if the deployment configures an override without both a provider and model identifier" do
    setup do
      previous_client = Application.get_env(:jido_gralkor, :client)
      previous_falkordb = Application.get_env(:jido_gralkor, :falkordb)
      previous_dir = System.get_env("GRALKOR_DATA_DIR")

      Application.delete_env(:jido_gralkor, :client)
      Application.delete_env(:jido_gralkor, :falkordb)
      System.put_env("GRALKOR_DATA_DIR", "/tmp/gralkor_provider_selection_never_started")

      on_exit(fn ->
        if previous_client,
          do: Application.put_env(:jido_gralkor, :client, previous_client),
          else: Application.delete_env(:jido_gralkor, :client)

        if previous_falkordb,
          do: Application.put_env(:jido_gralkor, :falkordb, previous_falkordb),
          else: Application.delete_env(:jido_gralkor, :falkordb)

        if previous_dir,
          do: System.put_env("GRALKOR_DATA_DIR", previous_dir),
          else: System.delete_env("GRALKOR_DATA_DIR")
      end)

      :ok
    end

    test "then startup fails before client construction" do
      credentials("google-key", "openai-key")

      for {llm, embedder} <- [
            {"missing-model:", "google:gemini-embedding-2-preview"},
            {"google:gemini-3.1-flash-lite", ":missing-provider"}
          ] do
        configure(llm, embedder)
        assert_raise ArgumentError, fn -> Gralkor.Application.children() end
      end
    end

    test "and the failure names the environment variable" do
      configure("missing-model:", "google:gemini-embedding-2-preview")

      assert_raise ArgumentError, ~r/GRALKOR_LLM_MODEL/, fn ->
        Gralkor.Application.children()
      end

      configure("google:gemini-3.1-flash-lite", ":missing-provider")

      assert_raise ArgumentError, ~r/GRALKOR_EMBEDDER_MODEL/, fn ->
        Gralkor.Application.children()
      end
    end

    test "and the failure names the rejected value" do
      configure("missing-model:", "google:gemini-embedding-2-preview")

      assert_raise ArgumentError, ~r/"missing-model:"/, fn ->
        Gralkor.Application.children()
      end

      configure("google:gemini-3.1-flash-lite", ":missing-provider")

      assert_raise ArgumentError, ~r/":missing-provider"/, fn ->
        Gralkor.Application.children()
      end
    end
  end

  describe "if the deployment configures LLM routes or a tuning setting that does not parse" do
    setup do
      previous_client = Application.get_env(:jido_gralkor, :client)
      previous_falkordb = Application.get_env(:jido_gralkor, :falkordb)
      previous_dir = System.get_env("GRALKOR_DATA_DIR")

      Application.delete_env(:jido_gralkor, :client)
      Application.delete_env(:jido_gralkor, :falkordb)
      System.put_env("GRALKOR_DATA_DIR", "/tmp/gralkor_provider_selection_never_started")

      on_exit(fn ->
        if previous_client,
          do: Application.put_env(:jido_gralkor, :client, previous_client),
          else: Application.delete_env(:jido_gralkor, :client)

        if previous_falkordb,
          do: Application.put_env(:jido_gralkor, :falkordb, previous_falkordb),
          else: Application.delete_env(:jido_gralkor, :falkordb)

        if previous_dir,
          do: System.put_env("GRALKOR_DATA_DIR", previous_dir),
          else: System.delete_env("GRALKOR_DATA_DIR")
      end)

      credentials("google-key", "openai-key")
      configure("openai:gpt-5.4-mini", "openai:text-embedding-3-small")
      :ok
    end

    @unparsable [
      {"GRALKOR_LLM_ROUTES", "[not-an-object]"},
      {"GRALKOR_LLM_TEMPERATURE", "warm"},
      {"GRALKOR_LLM_MAX_TOKENS", "lots"},
      {"GRALKOR_LLM_THINKING_BUDGET", "-2"},
      {"GRALKOR_EMBEDDER_DIMENSION", "-768"},
      {"GRALKOR_EMBEDDER_BATCH_SIZE", "1.5"}
    ]

    test "then startup fails before client construction" do
      for {var, value} <- @unparsable do
        System.put_env(var, value)
        assert_raise ArgumentError, fn -> Gralkor.Application.children() end
        System.delete_env(var)
      end
    end

    test "and the failure names the environment variable" do
      for {var, value} <- @unparsable do
        System.put_env(var, value)
        assert_raise ArgumentError, ~r/#{var}/, fn -> Gralkor.Application.children() end
        System.delete_env(var)
      end
    end

    test "and the failure names the rejected value" do
      for {var, value} <- @unparsable do
        System.put_env(var, value)

        assert_raise ArgumentError, ~r/#{Regex.escape(inspect(value))}/, fn ->
          Gralkor.Application.children()
        end

        System.delete_env(var)
      end
    end
  end

  describe "if the native memory runtime receives an unsupported provider" do
    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)
      :ok
    end

    test "then startup fails before client construction and names every model spec and the supported providers" do
      credentials("google-key", "openai-key")
      configure("anthropic:claude-opus-5", "google:gemini-embedding-2-preview")
      System.put_env("GRALKOR_RERANKER_MODEL", "openai:gpt-4.1-nano")

      System.put_env(
        "GRALKOR_LLM_ROUTES",
        ~s({"extract_edges": {"model": "google:gemini-3-flash"}})
      )

      assert {:error, {%ArgumentError{} = error, _}} = start_memory_runtime(self())

      message = Exception.message(error)
      assert message =~ "anthropic"
      assert message =~ "gemini-embedding-2-preview"
      assert message =~ "gpt-4.1-nano"
      assert message =~ "gemini-3-flash"
      assert message =~ "openai"
      assert message =~ "google"
      refute_received {:constructed, _}
    end
  end

  describe "if the native memory runtime receives an absent or blank credential" do
    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)
      :ok
    end

    test "then startup fails before client construction and names the credential and its role" do
      configure("openai:gpt-4.1-mini", "google:gemini-embedding-2-preview")
      credentials("google-key", nil)

      assert {:error, {%ArgumentError{} = absent, _}} = start_memory_runtime(self())
      assert Exception.message(absent) =~ "OPENAI_API_KEY"
      assert Exception.message(absent) =~ "llm"
      refute_received {:constructed, _}

      credentials("google-key", "")

      assert {:error, {%ArgumentError{} = blank, _}} = start_memory_runtime(self())
      assert Exception.message(blank) =~ "OPENAI_API_KEY"
      assert Exception.message(blank) =~ "llm"
      refute_received {:constructed, _}
    end
  end

  describe "where the native memory runtime does not configure a provider for any role" do
    test "then that provider's absent credential does not prevent startup" do
      configure("google:gemini-3.1-flash-lite", "google:gemini-embedding-2-preview")
      credentials("google-key", nil)

      assert {:ok, pid} = start_memory_runtime(self())
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "where the deployment has not opted into the native memory runtime" do
    setup do
      previous_client = Application.get_env(:jido_gralkor, :client)
      previous_dir = System.get_env("GRALKOR_DATA_DIR")
      previous_falkordb = Application.get_env(:jido_gralkor, :falkordb)

      Application.delete_env(:jido_gralkor, :falkordb)
      System.delete_env("GRALKOR_DATA_DIR")
      Application.delete_env(:jido_gralkor, :client)

      on_exit(fn ->
        if previous_client,
          do: Application.put_env(:jido_gralkor, :client, previous_client),
          else: Application.delete_env(:jido_gralkor, :client)

        if previous_falkordb,
          do: Application.put_env(:jido_gralkor, :falkordb, previous_falkordb),
          else: Application.delete_env(:jido_gralkor, :falkordb)

        if previous_dir, do: System.put_env("GRALKOR_DATA_DIR", previous_dir)
      end)

      :ok
    end

    test "then unsupported or uncredentialed provider settings do not affect startup" do
      configure("anthropic:claude-opus-5", "cohere:embed-english-v3.0")
      credentials(nil, nil)

      # No backend is selected, so the supervisor has no pool to start and
      # nothing ever reaches provider validation.
      assert Gralkor.Application.children() == []
    end
  end
end
