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

  @vars ~w(GRALKOR_LLM_MODEL GRALKOR_EMBEDDER_MODEL GOOGLE_API_KEY OPENAI_API_KEY)

  setup do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

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
  # construction is the substituted boundary.
  defp start_memory_runtime(test_pid) do
    GraphitiPool.start_link(
      name: nil,
      table: :"provider_selection_#{System.unique_integer([:positive])}",
      falkordb_spec: {:embedded, "/tmp/never_used"},
      llm_model: Config.llm_model(),
      embedder_model: Config.embedder_model(),
      construct_shared_clients: fn llm, embedder ->
        send(test_pid, {:constructed, GraphitiPool.shared_client_spec(llm, embedder)})
        %{llm_client: nil, embedder: nil, cross_encoder: nil}
      end,
      construct_falkor_db: fn _ -> :stub_falkor_db end,
      construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
      initialise_instance: fn _ -> :ok end,
      install_loop_fn: fn -> :ok end,
      warmup: false
    )
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

    test "and an OpenAI LLM configures OpenAI reranking" do
      credentials("google-key", "openai-key")
      configure("openai:gpt-4.1-mini", "openai:text-embedding-3-small")

      {:ok, pid} = start_memory_runtime(self())

      assert_receive {:constructed, spec}
      assert spec.cross_encoder.provider == :openai
      GenServer.stop(pid)
    end

    test "and a Google LLM configures Google reranking" do
      credentials("google-key", "openai-key")
      configure("google:gemini-3.1-flash-lite", "google:gemini-embedding-2-preview")

      {:ok, pid} = start_memory_runtime(self())

      assert_receive {:constructed, spec}
      assert spec.cross_encoder.provider == :google
      GenServer.stop(pid)
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

    test "and an OpenAI LLM that rejects `minimal` receives `none` explicitly instead of the graph library's default" do
      credentials("google-key", "openai-key")

      for llm <- ["openai:gpt-5.5", "openai:gpt-5.6-luna"] do
        configure(llm, "openai:text-embedding-3-small")
        {:ok, pid} = start_memory_runtime(self())

        assert_receive {:constructed, spec}
        assert spec.llm.reasoning == "none"
        GenServer.stop(pid)
      end

      configure("openai:gpt-5.6-luna", "openai:text-embedding-3-small")
      data_dir = Path.join(System.tmp_dir!(), "gralkor_reasoning_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(data_dir) end)

      {:ok, pid} =
        GraphitiPool.start_link(
          name: nil,
          table: :"provider_reasoning_#{System.unique_integer([:positive])}",
          falkordb_spec: {:embedded, data_dir},
          llm_model: Config.llm_model(),
          embedder_model: Config.embedder_model(),
          construct_falkor_db: fn _ -> :stub_falkor_db end,
          construct_instance: fn _, _, group -> {:stub_graphiti, group} end,
          initialise_instance: fn _ -> :ok end,
          install_loop_fn: fn -> :ok end,
          warmup: false
        )

      client = :sys.get_state(pid).shared.llm_client
      {reasoning, _} = Pythonx.eval("client.reasoning", %{"client" => client})
      assert Pythonx.decode(reasoning) == "none"
      GenServer.stop(pid)
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

  describe "if the native memory runtime receives an unsupported provider" do
    setup do
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)
      :ok
    end

    test "then startup fails before client construction and names both model specs and the supported providers" do
      credentials("google-key", "openai-key")
      configure("anthropic:claude-opus-5", "google:gemini-embedding-2-preview")

      assert {:error, {%ArgumentError{} = error, _}} = start_memory_runtime(self())

      message = Exception.message(error)
      assert message =~ "anthropic"
      assert message =~ "gemini-embedding-2-preview"
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

  describe "where the native memory runtime does not configure a provider for either role" do
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
