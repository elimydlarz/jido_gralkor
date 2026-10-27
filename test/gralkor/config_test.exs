defmodule Gralkor.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Gralkor.Config

  @settings ~w(
    GRALKOR_RERANKER_MODEL GRALKOR_LLM_ROUTES GRALKOR_LLM_TEMPERATURE GRALKOR_LLM_MAX_TOKENS
    GRALKOR_LLM_REASONING GRALKOR_LLM_VERBOSITY GRALKOR_LLM_THINKING_BUDGET
    GRALKOR_EMBEDDER_DIMENSION GRALKOR_EMBEDDER_BATCH_SIZE
  )

  setup do
    original_data_dir = System.get_env("GRALKOR_DATA_DIR")
    original_llm = System.get_env("GRALKOR_LLM_MODEL")
    original_embedder = System.get_env("GRALKOR_EMBEDDER_MODEL")
    original_falkordb = Application.get_env(:jido_gralkor, :falkordb)
    original_settings = Map.new(@settings, &{&1, System.get_env(&1)})

    original_socket_timeout =
      Application.get_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms)

    on_exit(fn ->
      restore_env("GRALKOR_DATA_DIR", original_data_dir)
      restore_env("GRALKOR_LLM_MODEL", original_llm)
      restore_env("GRALKOR_EMBEDDER_MODEL", original_embedder)
      Enum.each(original_settings, fn {key, value} -> restore_env(key, value) end)

      case original_falkordb do
        nil -> Application.delete_env(:jido_gralkor, :falkordb)
        v -> Application.put_env(:jido_gralkor, :falkordb, v)
      end

      case original_socket_timeout do
        nil -> Application.delete_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms)
        v -> Application.put_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms, v)
      end
    end)

    System.delete_env("GRALKOR_DATA_DIR")
    System.delete_env("GRALKOR_LLM_MODEL")
    System.delete_env("GRALKOR_EMBEDDER_MODEL")
    Enum.each(@settings, &System.delete_env/1)
    Application.delete_env(:jido_gralkor, :falkordb)
    Application.delete_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms)
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

  describe "when the FalkorDB connection is resolved > while a data directory is set > while no remote configuration is set" do
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

  describe "when the FalkorDB connection is resolved > while the data directory is blank or only whitespace" do
    test "then it counts as unset" do
      for blank <- ["", "   ", "\t\n "] do
        System.put_env("GRALKOR_DATA_DIR", blank)
        assert Config.falkordb_spec() == nil
      end
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

        assert_raise ArgumentError, ~r/:host.*got #{Regex.escape(inspect(host))}$/, fn ->
          Config.falkordb_spec()
        end
      end
    end
  end

  describe "if the remote FalkorDB port is not a positive integer" do
    test "then resolving the connection raises, naming the offending value" do
      for port <- [0, -1, "6379", 6379.0] do
        Application.put_env(:jido_gralkor, :falkordb, host: "h", port: port)

        assert_raise ArgumentError, ~r/:port.*got #{Regex.escape(inspect(port))}$/, fn ->
          Config.falkordb_spec()
        end
      end
    end
  end

  describe "when the embedded FalkorDB socket timeout is resolved > while no timeout is configured" do
    test "then sixty thousand milliseconds is returned" do
      assert Config.embedded_falkordb_socket_timeout_ms() == 60_000
    end
  end

  describe "when the embedded FalkorDB socket timeout is resolved > while a positive integer timeout is configured" do
    test "then that timeout is returned unchanged" do
      Application.put_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms, 12_345)

      assert Config.embedded_falkordb_socket_timeout_ms() == 12_345
    end
  end

  describe "if the embedded FalkorDB socket timeout is not a positive integer" do
    test "then resolving the timeout raises, naming the setting and its offending value" do
      for invalid <- [0, -1, "slow"] do
        Application.put_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms, invalid)

        assert_raise ArgumentError,
                     ~r/:embedded_falkordb_socket_timeout_ms.*#{Regex.escape(inspect(invalid))}/,
                     fn -> Config.embedded_falkordb_socket_timeout_ms() end
      end
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
          spec = Config.llm_model()
          refute is_struct(spec)
          assert spec == %{provider: :google, id: "not-yet-catalogued"}
        end)

      assert stderr == ""
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

        assert_raise ArgumentError,
                     ~r/GRALKOR_EMBEDDER_MODEL.*got #{Regex.escape(inspect(value))}$/,
                     fn -> Config.embedder_model() end
      end

      for value <- ["google:", "google:   "] do
        System.put_env("GRALKOR_LLM_MODEL", value)

        assert_raise ArgumentError,
                     ~r/GRALKOR_LLM_MODEL.*got #{Regex.escape(inspect(value))}$/,
                     fn -> Config.llm_model() end
      end
    end
  end

  describe "when the reranker model is resolved > while a provider and a model id joined by a colon are configured" do
    test "then a spec carrying that provider as an atom and that model id as a string is returned" do
      System.put_env("GRALKOR_RERANKER_MODEL", " openai : gpt-4.1-nano ")
      assert Config.reranker_model() == %{provider: :openai, id: "gpt-4.1-nano"}
    end
  end

  describe "when the reranker model is resolved > while no reranker model is configured, or it is blank" do
    test "then nothing is returned" do
      assert Config.reranker_model() == nil

      for blank <- ["", "  \t "] do
        System.put_env("GRALKOR_RERANKER_MODEL", blank)
        assert Config.reranker_model() == nil
      end
    end
  end

  describe "if the reranker model omits the colon separator or leaves the provider or the model id blank" do
    test "then resolving the reranker model raises, naming the environment variable and the offending value" do
      for value <- ["gpt-4.1-nano", ":gpt-4.1-nano", "openai:  "] do
        System.put_env("GRALKOR_RERANKER_MODEL", value)

        assert_raise ArgumentError,
                     ~r/GRALKOR_RERANKER_MODEL.*got #{Regex.escape(inspect(value))}$/,
                     fn -> Config.reranker_model() end
      end
    end
  end

  describe "when the LLM routes are resolved > while they are configured as a JSON object keyed by prompt group or group-qualified prompt name" do
    test "then each key's route is returned carrying its model spec and the tuning it sets" do
      System.put_env(
        "GRALKOR_LLM_ROUTES",
        Jason.encode!(%{
          "extract_edges" => %{"model" => "google:gemini-3-flash", "thinking_budget" => 512},
          "extract_edges.extract_timestamps" => %{
            "model" => "openai:gpt-5.4-nano",
            "max_tokens" => 2048,
            "temperature" => 0.5,
            "reasoning" => "low",
            "verbosity" => "high"
          },
          "eval" => %{"model" => " openai : gpt-5.4-mini "},
          "dedupe_nodes" => %{"model" => "google:gemini-3-flash", "thinking_budget" => 0},
          "summarize_nodes" => %{"model" => "google:gemini-3-flash", "thinking_budget" => -1}
        })
      )

      assert Config.llm_routes() == %{
               "extract_edges" => %{
                 model: %{provider: :google, id: "gemini-3-flash"},
                 tuning: %{thinking_budget: 512}
               },
               "extract_edges.extract_timestamps" => %{
                 model: %{provider: :openai, id: "gpt-5.4-nano"},
                 tuning: %{
                   max_tokens: 2048,
                   temperature: 0.5,
                   reasoning: "low",
                   verbosity: "high"
                 }
               },
               "eval" => %{model: %{provider: :openai, id: "gpt-5.4-mini"}, tuning: %{}},
               "dedupe_nodes" => %{
                 model: %{provider: :google, id: "gemini-3-flash"},
                 tuning: %{thinking_budget: 0}
               },
               "summarize_nodes" => %{
                 model: %{provider: :google, id: "gemini-3-flash"},
                 tuning: %{thinking_budget: -1}
               }
             }
    end
  end

  describe "when the LLM routes are resolved > while no LLM routes are configured, or they are blank" do
    test "then no routes are returned" do
      assert Config.llm_routes() == %{}

      for blank <- ["", "   "] do
        System.put_env("GRALKOR_LLM_ROUTES", blank)
        assert Config.llm_routes() == %{}
      end
    end
  end

  describe "if the LLM routes are not a JSON object" do
    test "then resolving them raises, naming the environment variable and the offending value" do
      for value <- ["[]", "\"extract_edges\"", "{not json"] do
        System.put_env("GRALKOR_LLM_ROUTES", value)

        assert_raise ArgumentError,
                     ~r/GRALKOR_LLM_ROUTES.*got #{Regex.escape(inspect(value))}$/,
                     fn -> Config.llm_routes() end
      end
    end
  end

  describe "if an LLM route's key names neither a prompt group nor a prompt of that group" do
    test "then resolving them raises, naming the key and the accepted prompt names" do
      for key <- ["extract_everything", "extract_edges.resolve_edge", "extract_edges."] do
        System.put_env("GRALKOR_LLM_ROUTES", Jason.encode!(%{key => %{"model" => "openai:m"}}))

        error = assert_raise ArgumentError, fn -> Config.llm_routes() end
        message = Exception.message(error)
        assert message =~ inspect(key)
        assert message =~ "dedupe_edges.resolve_edge"
        assert message =~ "extract_edges.extract_timestamps"
        assert message =~ "summarize_sagas"
      end
    end
  end

  describe "if an LLM route's model is not a provider and a model id joined by a colon" do
    test "then resolving them raises, naming the key and the offending value" do
      for model <- ["gpt-5.4-nano", ":gpt-5.4-nano", "openai: ", 42, nil] do
        System.put_env("GRALKOR_LLM_ROUTES", Jason.encode!(%{"eval" => %{"model" => model}}))

        error = assert_raise ArgumentError, fn -> Config.llm_routes() end
        assert Exception.message(error) =~ ~s("eval")
        assert Exception.message(error) =~ inspect(model)
      end

      System.put_env("GRALKOR_LLM_ROUTES", Jason.encode!(%{"eval" => %{"max_tokens" => 10}}))
      error = assert_raise ArgumentError, fn -> Config.llm_routes() end
      assert Exception.message(error) =~ ~s("eval")
      assert Exception.message(error) =~ "nil"

      System.put_env("GRALKOR_LLM_ROUTES", Jason.encode!(%{"eval" => "openai:gpt-5.4-nano"}))
      error = assert_raise ArgumentError, fn -> Config.llm_routes() end
      assert Exception.message(error) =~ ~s("eval")
      assert Exception.message(error) =~ ~s("openai:gpt-5.4-nano")
    end
  end

  describe "if an LLM route sets a field that is neither its model nor a tuning setting" do
    test "then resolving them raises, naming the key and the field" do
      System.put_env(
        "GRALKOR_LLM_ROUTES",
        Jason.encode!(%{"dedupe_nodes" => %{"model" => "openai:m", "top_p" => 0.9}})
      )

      error = assert_raise ArgumentError, fn -> Config.llm_routes() end
      assert Exception.message(error) =~ ~s("dedupe_nodes")
      assert Exception.message(error) =~ ~s("top_p")
    end
  end

  describe "if an LLM route's tuning value does not parse as its setting's type" do
    test "then resolving them raises, naming the key, the setting, and the offending value" do
      for {setting, value} <- [
            {"max_tokens", 0},
            {"max_tokens", "100"},
            {"max_tokens", 1.5},
            {"thinking_budget", -2},
            {"thinking_budget", 1.5},
            {"thinking_budget", "0"},
            {"temperature", "warm"},
            {"reasoning", 3},
            {"reasoning", " "},
            {"verbosity", false}
          ] do
        System.put_env(
          "GRALKOR_LLM_ROUTES",
          Jason.encode!(%{"summarize_nodes" => %{"model" => "openai:m", setting => value}})
        )

        error = assert_raise ArgumentError, fn -> Config.llm_routes() end
        message = Exception.message(error)
        assert message =~ ~s("summarize_nodes")
        assert message =~ setting
        assert message =~ inspect(value)
      end
    end
  end

  describe "when an inference tuning setting is resolved > while it is configured" do
    test "then its value is returned parsed as that setting's type" do
      System.put_env("GRALKOR_LLM_TEMPERATURE", " 0.25 ")
      System.put_env("GRALKOR_LLM_MAX_TOKENS", "4096")
      System.put_env("GRALKOR_LLM_REASONING", "low")
      System.put_env("GRALKOR_LLM_VERBOSITY", " high ")
      System.put_env("GRALKOR_LLM_THINKING_BUDGET", "1024")
      System.put_env("GRALKOR_EMBEDDER_DIMENSION", "768")
      System.put_env("GRALKOR_EMBEDDER_BATCH_SIZE", "16")

      assert Config.llm_tuning() == %{
               temperature: 0.25,
               max_tokens: 4096,
               reasoning: "low",
               verbosity: "high",
               thinking_budget: 1024
             }

      assert Config.embedder_dimension() == 768
      assert Config.embedder_batch_size() == 16

      System.put_env("GRALKOR_LLM_TEMPERATURE", "1")
      assert Config.llm_tuning().temperature == 1.0

      for budget <- [0, -1] do
        System.put_env("GRALKOR_LLM_THINKING_BUDGET", " #{budget} ")
        assert Config.llm_tuning().thinking_budget == budget
      end
    end
  end

  describe "when an inference tuning setting is resolved > while it is not configured, or it is blank" do
    test "then nothing is returned" do
      assert Config.llm_tuning() == %{}
      assert Config.embedder_dimension() == nil
      assert Config.embedder_batch_size() == nil

      for setting <- @settings, do: System.put_env(setting, "  ")

      assert Config.llm_tuning() == %{}
      assert Config.embedder_dimension() == nil
      assert Config.embedder_batch_size() == nil
    end
  end

  describe "if the max tokens, embedder dimension, or embedder batch size is not a positive integer" do
    test "then resolving it raises, naming the environment variable and the offending value" do
      for {var, resolve} <- [
            {"GRALKOR_LLM_MAX_TOKENS", &Config.llm_tuning/0},
            {"GRALKOR_EMBEDDER_DIMENSION", &Config.embedder_dimension/0},
            {"GRALKOR_EMBEDDER_BATCH_SIZE", &Config.embedder_batch_size/0}
          ],
          value <- ["0", "-5", "1.5", "many"] do
        System.put_env(var, value)

        assert_raise ArgumentError, ~r/#{var}.*got #{Regex.escape(inspect(value))}$/, resolve

        System.delete_env(var)
      end
    end
  end

  describe "if the thinking budget is not an integer of at least -1" do
    test "then resolving it raises, naming the environment variable and the offending value" do
      for value <- ["-2", "-50", "1.5", "-1.0", "many"] do
        System.put_env("GRALKOR_LLM_THINKING_BUDGET", value)

        assert_raise ArgumentError,
                     ~r/GRALKOR_LLM_THINKING_BUDGET.*got #{Regex.escape(inspect(value))}$/,
                     fn -> Config.llm_tuning() end
      end
    end
  end

  describe "if the LLM temperature is not a number" do
    test "then resolving it raises, naming the environment variable and the offending value" do
      for value <- ["warm", "0.2x", "."] do
        System.put_env("GRALKOR_LLM_TEMPERATURE", value)

        assert_raise ArgumentError,
                     ~r/GRALKOR_LLM_TEMPERATURE.*got #{Regex.escape(inspect(value))}$/,
                     fn -> Config.llm_tuning() end
      end
    end
  end
end
