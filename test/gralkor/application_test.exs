defmodule Gralkor.ApplicationTest do
  use ExUnit.Case, async: false

  alias Gralkor.Application, as: App

  setup do
    original_env = System.get_env("GRALKOR_DATA_DIR")
    original_client = Application.get_env(:jido_gralkor, :client)
    original_falkordb = Application.get_env(:jido_gralkor, :falkordb)
    original_reflection_storage = Application.get_env(:jido_gralkor, :reflection_storage)

    on_exit(fn ->
      case original_env do
        nil -> System.delete_env("GRALKOR_DATA_DIR")
        v -> System.put_env("GRALKOR_DATA_DIR", v)
      end

      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        v -> Application.put_env(:jido_gralkor, :client, v)
      end

      case original_falkordb do
        nil -> Application.delete_env(:jido_gralkor, :falkordb)
        v -> Application.put_env(:jido_gralkor, :falkordb, v)
      end

      case original_reflection_storage do
        nil -> Application.delete_env(:jido_gralkor, :reflection_storage)
        v -> Application.put_env(:jido_gralkor, :reflection_storage, v)
      end
    end)

    Application.delete_env(:jido_gralkor, :client)
    Application.delete_env(:jido_gralkor, :falkordb)
    Application.delete_env(:jido_gralkor, :reflection_storage)
    :ok
  end

  describe "when the application starts > while neither a remote connection nor a data directory is configured" do
    test "then no children are supervised, because the consumer has not opted into the native runtime" do
      System.delete_env("GRALKOR_DATA_DIR")

      assert [] = App.children()
    end
  end

  describe "when the application starts > while a data directory is configured > while no remote connection is configured" do
    test "then the Python runtime and graph pool are supervised in that order" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      children = App.children()

      assert [{Gralkor.Python, [reap_orphans: true]}, {Gralkor.GraphitiPool, _}] = children
    end

    test "and the graph pool is constructed with the embedded connection" do
      data_dir =
        Path.join(
          System.tmp_dir!(),
          "ex_app_test_#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}"
        )

      System.put_env("GRALKOR_DATA_DIR", data_dir)

      [_python, {Gralkor.GraphitiPool, opts}] = App.children()

      assert Keyword.fetch!(opts, :falkordb_spec) == {:embedded, Path.expand(data_dir)}
    end

    test "and the graph pool receives the configured embedded socket timeout" do
      configure_embedded_socket_timeout(12_345)
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      [_python, {Gralkor.GraphitiPool, opts}] = App.children()

      assert Keyword.fetch!(opts, :embedded_falkordb_socket_timeout_ms) == 12_345
    end

    test "and the Python runtime is told to sweep for orphaned embedded servers, this deployment spawning one of its own" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      assert [{Gralkor.Python, [reap_orphans: true]}, _] = App.children()
    end
  end

  describe "when the application starts > while a remote FalkorDB connection is configured" do
    test "then the Python runtime and graph pool are supervised in that order" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      children = App.children()

      assert Enum.map(children, fn {module, _opts} -> module end) == [
               Gralkor.Python,
               Gralkor.GraphitiPool
             ]
    end

    test "and the graph pool is constructed with the remote connection, so no embedded server is spawned" do
      Application.put_env(:jido_gralkor, :falkordb,
        host: "falkor.example",
        port: 6379,
        username: "alice",
        password: "secret"
      )

      [_python, {Gralkor.GraphitiPool, opts}] = App.children()

      assert Keyword.fetch!(opts, :falkordb_spec) ==
               {:remote,
                [host: "falkor.example", port: 6379, username: "alice", password: "secret"]}
    end

    test "and the graph pool receives no embedded socket timeout" do
      configure_embedded_socket_timeout(12_345)
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      [_python, {Gralkor.GraphitiPool, opts}] = App.children()

      refute Keyword.has_key?(opts, :embedded_falkordb_socket_timeout_ms)
    end

    test "and the Python runtime is told not to sweep for orphaned embedded servers, this deployment never having spawned one" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      assert [{Gralkor.Python, [reap_orphans: false]}, _] = App.children()
    end

    test "and a configured data directory is ignored" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      [{Gralkor.Python, [reap_orphans: false]}, {Gralkor.GraphitiPool, opts}] =
        App.children()

      assert {:remote, _} = Keyword.fetch!(opts, :falkordb_spec)
    end
  end

  describe "if the remote FalkorDB configuration is not a keyword list carrying a host and a port" do
    test "then startup raises before any child starts" do
      Application.put_env(:jido_gralkor, :falkordb, port: 6379)
      assert_raise ArgumentError, ~r/:host/, fn -> App.children() end

      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example")
      assert_raise ArgumentError, ~r/:port/, fn -> App.children() end

      Application.put_env(:jido_gralkor, :falkordb, "falkor://host:6379")
      assert_raise ArgumentError, ~r/keyword list/, fn -> App.children() end
    end
  end

  describe "if the retired `:reflection_storage` setting is configured" do
    test "then application startup fails identifying Destination outputs as the artefact memory boundary" do
      Application.put_env(:jido_gralkor, :reflection_storage, LegacyReflectionStorage)

      assert_raise ArgumentError, ~r/Destination outputs are the artefact memory boundary/, fn ->
        App.children()
      end
    end
  end

  describe "when the application starts > while the in-memory client is configured" do
    test "then no children are supervised regardless of configured local or remote storage" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.InMemory)

      assert [] = App.children()
    end
  end

  defp configure_embedded_socket_timeout(timeout_ms) do
    original = Application.get_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms)
        value -> Application.put_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms, value)
      end
    end)

    Application.put_env(:jido_gralkor, :embedded_falkordb_socket_timeout_ms, timeout_ms)
  end
end
