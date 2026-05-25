defmodule Gralkor.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Gralkor.Config

  setup do
    original_data_dir = System.get_env("GRALKOR_DATA_DIR")
    original_llm = System.get_env("GRALKOR_LLM_MODEL")
    original_embedder = System.get_env("GRALKOR_EMBEDDER_MODEL")
    original_falkordb = Application.get_env(:jido_gralkor, :falkordb)
    original_ontology = Application.get_env(:jido_gralkor, :ontology)

    on_exit(fn ->
      restore_env("GRALKOR_DATA_DIR", original_data_dir)
      restore_env("GRALKOR_LLM_MODEL", original_llm)
      restore_env("GRALKOR_EMBEDDER_MODEL", original_embedder)

      case original_falkordb do
        nil -> Application.delete_env(:jido_gralkor, :falkordb)
        v -> Application.put_env(:jido_gralkor, :falkordb, v)
      end

      case original_ontology do
        nil -> Application.delete_env(:jido_gralkor, :ontology)
        v -> Application.put_env(:jido_gralkor, :ontology, v)
      end
    end)

    System.delete_env("GRALKOR_DATA_DIR")
    System.delete_env("GRALKOR_LLM_MODEL")
    System.delete_env("GRALKOR_EMBEDDER_MODEL")
    Application.delete_env(:jido_gralkor, :falkordb)
    Application.delete_env(:jido_gralkor, :ontology)
    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, ""), do: System.put_env(key, "")
  defp restore_env(key, v), do: System.put_env(key, v)

  describe "falkordb-connection > when neither :falkordb nor GRALKOR_DATA_DIR is set" do
    test "returns nil" do
      assert Config.falkordb_spec() == nil
    end
  end

  describe "falkordb-connection > when GRALKOR_DATA_DIR is set and :falkordb is unset" do
    test "returns {:embedded, expanded_path}" do
      System.put_env("GRALKOR_DATA_DIR", "/tmp/gralkor")
      assert Config.falkordb_spec() == {:embedded, "/tmp/gralkor"}
    end

    test "expands ~ in the data dir" do
      System.put_env("GRALKOR_DATA_DIR", "~/gralkor")
      assert {:embedded, expanded} = Config.falkordb_spec()
      refute String.starts_with?(expanded, "~")
    end
  end

  describe "falkordb-connection > when :falkordb is set with :host and :port" do
    test "returns {:remote, kw} with the keyword list unchanged" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)
      assert Config.falkordb_spec() == {:remote, [host: "falkor.example", port: 6379]}
    end

    test "remote wins when GRALKOR_DATA_DIR is also set" do
      System.put_env("GRALKOR_DATA_DIR", "/tmp/should_be_ignored")
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)
      assert {:remote, _} = Config.falkordb_spec()
    end

    test "carries username and password through" do
      Application.put_env(:jido_gralkor, :falkordb,
        host: "falkor.example",
        port: 6379,
        username: "alice",
        password: "secret"
      )

      assert {:remote, kw} = Config.falkordb_spec()
      assert Keyword.fetch!(kw, :username) == "alice"
      assert Keyword.fetch!(kw, :password) == "secret"
    end
  end

  describe "falkordb-connection > when :falkordb is misconfigured" do
    test "raises when :host is missing" do
      Application.put_env(:jido_gralkor, :falkordb, port: 6379)
      assert_raise ArgumentError, ~r/:host/, fn -> Config.falkordb_spec() end
    end

    test "raises when :port is missing" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example")
      assert_raise ArgumentError, ~r/:port/, fn -> Config.falkordb_spec() end
    end

    test "raises when :host is blank" do
      Application.put_env(:jido_gralkor, :falkordb, host: "", port: 6379)
      assert_raise ArgumentError, ~r/:host/, fn -> Config.falkordb_spec() end
    end

    test "raises when :port is not a positive integer" do
      Application.put_env(:jido_gralkor, :falkordb, host: "h", port: 0)
      assert_raise ArgumentError, ~r/:port/, fn -> Config.falkordb_spec() end
    end

    test "raises when :falkordb is not a keyword list" do
      Application.put_env(:jido_gralkor, :falkordb, "falkor://host:6379")
      assert_raise ArgumentError, ~r/keyword list/, fn -> Config.falkordb_spec() end
    end
  end

  describe "ex-config-defaults > model-spec shape > llm_model and embedder_model" do
    test "default to the canonical google models as %{provider:, id:} maps when env is unset" do
      assert Config.llm_model() == %{provider: :google, id: "gemini-3.1-flash-lite"}
      assert Config.embedder_model() == %{provider: :google, id: "gemini-embedding-2-preview"}
    end

    test "GRALKOR_LLM_MODEL is parsed to a map" do
      System.put_env("GRALKOR_LLM_MODEL", "openai:gpt-4")
      assert Config.llm_model() == %{provider: :openai, id: "gpt-4"}
    end

    test "GRALKOR_EMBEDDER_MODEL is parsed to a map" do
      System.put_env("GRALKOR_EMBEDDER_MODEL", "openai:text-embedding-3-small")
      assert Config.embedder_model() == %{provider: :openai, id: "text-embedding-3-small"}
    end

    test "model ids may contain colons (provider is split off first only)" do
      System.put_env("GRALKOR_LLM_MODEL", "anthropic:claude-3:opus")
      assert Config.llm_model() == %{provider: :anthropic, id: "claude-3:opus"}
    end

    test "blank env values fall back to defaults" do
      System.put_env("GRALKOR_LLM_MODEL", "")
      assert Config.llm_model() == %{provider: :google, id: "gemini-3.1-flash-lite"}
    end

    test "GRALKOR_LLM_MODEL without a colon raises ArgumentError naming the env var and value" do
      System.put_env("GRALKOR_LLM_MODEL", "gemini-3.1-flash-lite")

      assert_raise ArgumentError, ~r/GRALKOR_LLM_MODEL.*gemini-3\.1-flash-lite/, fn ->
        Config.llm_model()
      end
    end

    test "GRALKOR_EMBEDDER_MODEL with a blank provider half raises ArgumentError" do
      System.put_env("GRALKOR_EMBEDDER_MODEL", ":gemini-embedding-2-preview")

      assert_raise ArgumentError, ~r/GRALKOR_EMBEDDER_MODEL/, fn ->
        Config.embedder_model()
      end
    end

    test "GRALKOR_LLM_MODEL with a blank model half raises ArgumentError" do
      System.put_env("GRALKOR_LLM_MODEL", "google:")

      assert_raise ArgumentError, ~r/GRALKOR_LLM_MODEL/, fn ->
        Config.llm_model()
      end
    end

    test "the default llm_model shape is accepted by ReqLLM.model/1 without emitting an 'unverified model' IO.warn" do
      stderr =
        capture_io(:stderr, fn ->
          assert {:ok, %LLMDB.Model{}} = ReqLLM.model(Config.llm_model())
        end)

      refute stderr =~ "Using unverified model"
    end

    test "the default embedder_model shape is accepted by ReqLLM.model/1 without emitting an 'unverified model' IO.warn" do
      stderr =
        capture_io(:stderr, fn ->
          assert {:ok, %LLMDB.Model{}} = ReqLLM.model(Config.embedder_model())
        end)

      refute stderr =~ "Using unverified model"
    end
  end

  describe "ex-config-ontology > when :jido_gralkor, :ontology is unset" do
    test "returns nil" do
      assert Config.ontology() == nil
    end
  end

  describe "ex-config-ontology > when :jido_gralkor, :ontology is a module declared via use Gralkor.Ontology" do
    test "returns that module" do
      Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.Strict)
      assert Config.ontology() == Gralkor.TestOntologies.Strict
    end
  end

  describe "ex-config-ontology > if :jido_gralkor, :ontology is a module that does not export __ontology__/0, or any non-module value" do
    test "raises ArgumentError naming a module that is not an ontology" do
      Application.put_env(:jido_gralkor, :ontology, Gralkor.TestOntologies.NotAnOntology)

      assert_raise ArgumentError, ~r/NotAnOntology/, fn -> Config.ontology() end
    end

    test "raises ArgumentError naming a non-module value" do
      Application.put_env(:jido_gralkor, :ontology, "MyApp.Ontology")

      assert_raise ArgumentError, ~r/MyApp\.Ontology/, fn -> Config.ontology() end
    end
  end
end
