defmodule Gralkor.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Gralkor.Config

  setup do
    original_data_dir = System.get_env("GRALKOR_DATA_DIR")
    original_llm = System.get_env("GRALKOR_LLM_MODEL")
    original_embedder = System.get_env("GRALKOR_EMBEDDER_MODEL")
    original_falkordb = Application.get_env(:jido_gralkor, :falkordb)

    on_exit(fn ->
      restore_env("GRALKOR_DATA_DIR", original_data_dir)
      restore_env("GRALKOR_LLM_MODEL", original_llm)
      restore_env("GRALKOR_EMBEDDER_MODEL", original_embedder)

      case original_falkordb do
        nil -> Application.delete_env(:jido_gralkor, :falkordb)
        v -> Application.put_env(:jido_gralkor, :falkordb, v)
      end

    end)

    System.delete_env("GRALKOR_DATA_DIR")
    System.delete_env("GRALKOR_LLM_MODEL")
    System.delete_env("GRALKOR_EMBEDDER_MODEL")
    Application.delete_env(:jido_gralkor, :falkordb)
    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, ""), do: System.put_env(key, "")
  defp restore_env(key, v), do: System.put_env(key, v)

  describe "when the FalkorDB connection is resolved > while neither a remote configuration nor a data directory is set" do
    test "then nothing is returned, so the supervisor can start with no children" do
      assert Config.falkordb_spec() == nil
    end
  end

  describe "when the FalkorDB connection is resolved > while a data directory is set > and no remote configuration is set" do
    test "then an embedded connection carrying that data directory is returned" do
      System.put_env("GRALKOR_DATA_DIR", "/tmp/gralkor")
      assert Config.falkordb_spec() == {:embedded, "/tmp/gralkor"}
    end

    test "and a leading tilde in the data directory is expanded to an absolute path" do
      System.put_env("GRALKOR_DATA_DIR", "~/gralkor")
      assert {:embedded, expanded} = Config.falkordb_spec()
      refute String.starts_with?(expanded, "~")
    end
  end

  describe "when the FalkorDB connection is resolved > while a remote configuration carrying a host and a port is set" do
    test "then a remote connection carrying that configuration unchanged is returned" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)
      assert Config.falkordb_spec() == {:remote, [host: "falkor.example", port: 6379]}
    end

    test "and a supplied username and password are carried through unchanged" do
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

  describe "when the FalkorDB connection is resolved > while a remote configuration carrying a host and a port is set > while a data directory is also set" do
    test "then the remote connection is the one returned" do
      System.put_env("GRALKOR_DATA_DIR", "/tmp/should_be_ignored")
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)
      assert {:remote, _} = Config.falkordb_spec()
    end
  end

  describe "if the remote FalkorDB configuration is not a keyword list" do
    test "then resolving the connection raises, naming the offending value" do
      Application.put_env(:jido_gralkor, :falkordb, "falkor://host:6379")
      assert_raise ArgumentError, ~r/falkor:\/\/host:6379/, fn -> Config.falkordb_spec() end
    end
  end

  describe "if the remote FalkorDB configuration omits its host" do
    test "then resolving the connection raises, naming the missing host" do
      Application.put_env(:jido_gralkor, :falkordb, port: 6379)
      assert_raise ArgumentError, ~r/:host/, fn -> Config.falkordb_spec() end
    end
  end

  describe "if the remote FalkorDB configuration omits its port" do
    test "then resolving the connection raises, naming the missing port" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example")
      assert_raise ArgumentError, ~r/:port/, fn -> Config.falkordb_spec() end
    end
  end

  describe "if the remote FalkorDB host is blank" do
    test "then resolving the connection raises, naming the offending value" do
      for host <- ["", "   "] do
        Application.put_env(:jido_gralkor, :falkordb, host: host, port: 6379)
        assert_raise ArgumentError, ~r/host/, fn -> Config.falkordb_spec() end
      end
    end
  end

  describe "if the remote FalkorDB port is not a positive integer" do
    test "then resolving the connection raises, naming the offending value" do
      Application.put_env(:jido_gralkor, :falkordb, host: "h", port: 0)
      assert_raise ArgumentError, ~r/0/, fn -> Config.falkordb_spec() end
    end
  end

  describe "when a role's model override is configured as a provider and a model id joined by a colon" do
    test "then a spec carrying that provider as an atom and that model id as a string is returned" do
      System.put_env("GRALKOR_LLM_MODEL", "openai:gpt-4")
      assert Config.llm_model() == %{provider: :openai, id: "gpt-4"}
      System.put_env("GRALKOR_EMBEDDER_MODEL", "openai:text-embedding-3-small")
      assert Config.embedder_model() == %{provider: :openai, id: "text-embedding-3-small"}
    end

    test "and the returned spec is not narrowed to any particular provider, so provider support is decided where the inference clients are built" do
      System.put_env("GRALKOR_LLM_MODEL", "anthropic:claude-3")
      assert Config.llm_model() == %{provider: :anthropic, id: "claude-3"}
    end

    test "and only the first colon separates the provider from the model id, so a model id may itself contain colons" do
      System.put_env("GRALKOR_LLM_MODEL", "anthropic:claude-3:opus")
      assert Config.llm_model() == %{provider: :anthropic, id: "claude-3:opus"}
    end

    test "and the inline spec avoids a catalog lookup and unverified-model warning" do
      System.put_env("GRALKOR_LLM_MODEL", "google:not-yet-catalogued")

      stderr =
        capture_io(:stderr, fn ->
          assert {:ok, %LLMDB.Model{}} = ReqLLM.model(Config.llm_model())
        end)

      refute stderr =~ "Using unverified model"
    end

    test "and surrounding whitespace around the provider and model id is ignored" do
      System.put_env("GRALKOR_LLM_MODEL", "  openai : gpt-4.1  ")
      assert Config.llm_model() == %{provider: :openai, id: "gpt-4.1"}
    end
  end

  describe "when no model override is configured for a role" do
    test "then the Google default model spec for that role is returned" do
      assert Config.llm_model() == %{provider: :google, id: "gemini-3.1-flash-lite"}
      assert Config.embedder_model() == %{provider: :google, id: "gemini-embedding-2-preview"}
    end
  end

  describe "when a role's model override is configured as a blank value, including whitespace alone" do
    test "then the Google default model spec for that role is returned" do
      for blank <- ["", "  \t  "] do
        System.put_env("GRALKOR_LLM_MODEL", blank)
        System.put_env("GRALKOR_EMBEDDER_MODEL", blank)
        assert Config.llm_model() == %{provider: :google, id: "gemini-3.1-flash-lite"}
        assert Config.embedder_model() == %{provider: :google, id: "gemini-embedding-2-preview"}
      end
    end
  end

  describe "if a role's model override omits the colon separator" do
    test "then resolving that role's model raises, naming the environment variable and the offending value" do
      System.put_env("GRALKOR_LLM_MODEL", "gemini-3.1-flash-lite")

      assert_raise ArgumentError, ~r/GRALKOR_LLM_MODEL.*gemini-3\.1-flash-lite/, fn ->
        Config.llm_model()
      end
    end
  end

  describe "if a role's model override leaves the provider or the model id blank after surrounding whitespace is removed" do
    test "then resolving that role's model raises, naming the environment variable and the offending value" do
      for value <- [":gemini-embedding-2-preview", "  :gemini-embedding-2-preview"] do
        System.put_env("GRALKOR_EMBEDDER_MODEL", value)

        assert_raise ArgumentError, ~r/GRALKOR_EMBEDDER_MODEL/, fn ->
          Config.embedder_model()
        end
      end

      for value <- ["google:", "google:   "] do
        System.put_env("GRALKOR_LLM_MODEL", value)

        assert_raise ArgumentError, ~r/GRALKOR_LLM_MODEL/, fn ->
          Config.llm_model()
        end
      end
    end
  end

end
