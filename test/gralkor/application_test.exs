defmodule Gralkor.ApplicationTest do
  use ExUnit.Case, async: false

  require Logger

  alias Gralkor.Application, as: App

  setup do
    original_env = System.get_env("GRALKOR_DATA_DIR")
    original_client = Application.get_env(:jido_gralkor, :client)
    original_falkordb = Application.get_env(:jido_gralkor, :falkordb)
    original_gen_on_flush = Application.get_env(:jido_gralkor, :generalise_on_flush)

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

      case original_gen_on_flush do
        nil -> Application.delete_env(:jido_gralkor, :generalise_on_flush)
        v -> Application.put_env(:jido_gralkor, :generalise_on_flush, v)
      end
    end)

    Application.delete_env(:jido_gralkor, :client)
    Application.delete_env(:jido_gralkor, :falkordb)
    Application.delete_env(:jido_gralkor, :generalise_on_flush)
    :ok
  end

  describe "ex-application > start/2 child specs > when neither :falkordb nor GRALKOR_DATA_DIR is set" do
    test "the supervisor includes no children" do
      System.delete_env("GRALKOR_DATA_DIR")

      assert [] = App.children()
    end
  end

  describe "ex-application > start/2 child specs > when GRALKOR_DATA_DIR is set and :falkordb is unset (embedded)" do
    test "the supervisor includes Gralkor.Python, Gralkor.GraphitiPool, Gralkor.CaptureBuffer in order" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      children = App.children()

      assert length(children) == 3

      [first, second, third] = children

      assert {Gralkor.Python, [reap_orphans: true]} = first
      assert {Gralkor.GraphitiPool, _} = second
      assert {Gralkor.CaptureBuffer, _} = third
    end

    test "the same set is returned when client is explicitly Gralkor.Client.Native" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

      assert [
               {Gralkor.Python, [reap_orphans: true]},
               {Gralkor.GraphitiPool, _},
               {Gralkor.CaptureBuffer, _}
             ] = App.children()
    end

    test "GraphitiPool is configured with an :embedded falkordb_spec carrying the expanded data_dir" do
      data_dir = Path.join(System.tmp_dir!(), "ex_app_test_#{System.unique_integer([:positive])}")
      System.put_env("GRALKOR_DATA_DIR", data_dir)

      [_python, {Gralkor.GraphitiPool, opts}, _buffer] = App.children()

      assert Keyword.fetch!(opts, :falkordb_spec) == {:embedded, Path.expand(data_dir)}
    end

    test "CaptureBuffer is configured with a flush_callback function" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())

      [_python, _pool, {Gralkor.CaptureBuffer, opts}] = App.children()

      assert is_function(Keyword.fetch!(opts, :flush_callback), 5)
    end
  end

  describe "ex-application > start/2 child specs > when :falkordb is set (remote)" do
    test "the supervisor includes Gralkor.Python with reap_orphans: false, GraphitiPool with the remote spec, and CaptureBuffer" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      [{Gralkor.Python, [reap_orphans: false]}, {Gralkor.GraphitiPool, opts}, {Gralkor.CaptureBuffer, _}] =
        App.children()

      assert Keyword.fetch!(opts, :falkordb_spec) ==
               {:remote, [host: "falkor.example", port: 6379]}
    end

    test "remote wins over GRALKOR_DATA_DIR when both are set" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)

      [{Gralkor.Python, [reap_orphans: false]}, {Gralkor.GraphitiPool, opts}, _] = App.children()

      assert {:remote, _} = Keyword.fetch!(opts, :falkordb_spec)
    end

    test "username and password are carried through to the remote spec" do
      Application.put_env(:jido_gralkor, :falkordb,
        host: "falkor.example",
        port: 6379,
        username: "alice",
        password: "secret"
      )

      [_python, {Gralkor.GraphitiPool, opts}, _] = App.children()

      {:remote, kw} = Keyword.fetch!(opts, :falkordb_spec)
      assert Keyword.fetch!(kw, :username) == "alice"
      assert Keyword.fetch!(kw, :password) == "secret"
    end

    test "raises ArgumentError when :falkordb is missing :host" do
      Application.put_env(:jido_gralkor, :falkordb, port: 6379)

      assert_raise ArgumentError, ~r/:host/, fn -> App.children() end
    end

    test "raises ArgumentError when :falkordb is missing :port" do
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example")

      assert_raise ArgumentError, ~r/:port/, fn -> App.children() end
    end

    test "raises ArgumentError when :falkordb is not a keyword list" do
      Application.put_env(:jido_gralkor, :falkordb, "falkor://host:6379")

      assert_raise ArgumentError, ~r/keyword list/, fn -> App.children() end
    end
  end

  describe "ex-application > start/2 child specs > when `:jido_gralkor, :client` is configured to Gralkor.Client.InMemory" do
    test "the supervisor includes no children regardless of GRALKOR_DATA_DIR or :falkordb" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :falkordb, host: "falkor.example", port: 6379)
      Application.put_env(:jido_gralkor, :client, Gralkor.Client.InMemory)

      assert [] = App.children()
    end
  end

  describe "ex-capture > flush > when the distilled episode body is empty" do
    @tag :capture_log
    test "no episode is added and nothing is logged" do
      add_episode_fn = fn _g, _b, _s, _o -> flunk("add_episode should not be called") end

      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, ""} end,
          add_episode_fn: add_episode_fn
        )

      logs =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert :ok = cb.("g", "TestAgent", "Eli", nil, [])
        end)

      refute logs =~ "[gralkor] capture flushed"
      refute logs =~ "[gralkor] [test] capture flush body"
    end
  end

  describe "ex-capture > flush > when the episode is added" do
    @tag :capture_log
    test "logs the group, body size, and how long the add took" do
      add_episode_fn = fn _g, _b, _s, _o -> :ok end

      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "behaviour summary"} end,
          add_episode_fn: add_episode_fn
        )

      turns = [[Gralkor.Message.new("user", "hi"), Gralkor.Message.new("assistant", "hello")]]

      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      assert logs =~ "[gralkor] capture flushed"
      assert logs =~ "group:g1"
      assert logs =~ ~r/bodyChars:\d+/
      assert logs =~ ~r/\d+ms/
    end
  end

  describe "ex-capture > flush > when test mode is enabled" do
    setup do
      Application.put_env(:jido_gralkor, :test, true)
      on_exit(fn -> Application.delete_env(:jido_gralkor, :test) end)
      :ok
    end

    @tag :capture_log
    test "also logs the distilled episode body" do
      add_episode_fn = fn _g, _b, _s, _o -> :ok end

      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "behaviour summary"} end,
          add_episode_fn: add_episode_fn
        )

      turns = [[Gralkor.Message.new("user", "hi"), Gralkor.Message.new("assistant", "hello")]]

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      assert logs =~ "[gralkor] [test] capture flush body:"
      assert logs =~ "Eli: hi"
    end
  end

  describe "ex-capture > flush > when test mode is disabled" do
    @tag :capture_log
    test "does not log the distilled episode body" do
      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "behaviour summary"} end,
          add_episode_fn: fn _g, _b, _s, _o -> :ok end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      refute logs =~ "[gralkor] [test]"
    end
  end

  describe "ex-application > build_flush_callback/2 > when add_episode_fn returns :ok" do
    @tag :capture_log
    test "logs '[gralkor] capture flushed' at :info and returns :ok" do
      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "summary"} end,
          add_episode_fn: fn _g, _b, _s, _o -> :ok end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      assert logs =~ "[gralkor] capture flushed"
      assert logs =~ "group:g1"
      refute logs =~ "capture flush failed"
    end
  end

  describe "ex-application > build_flush_callback/2 > when add_episode_fn returns {:error, reason}" do
    @tag :capture_log
    test "does not log 'capture flushed', logs a concise warning, and returns the error unchanged" do
      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "summary"} end,
          add_episode_fn: fn _g, _b, _s, _o -> {:error, {:python, "ConnectionError: reset by peer"}} end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      logs =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:error, {:python, "ConnectionError: reset by peer"}} =
                   cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      refute logs =~ "[gralkor] capture flushed"
      assert logs =~ "[gralkor] capture flush failed"
      assert logs =~ "group:g1"
      assert logs =~ "retrying"
    end

    @tag :capture_log
    test "the warning is concise — it does not embed a multi-line traceback blob" do
      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "summary"} end,
          add_episode_fn: fn _g, _b, _s, _o -> {:error, :disk_full} end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      logs =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert {:error, :disk_full} = cb.("g1", "TestAgent", "Eli", nil, turns)
        end)

      flush_line =
        logs
        |> String.split("\n")
        |> Enum.find("", &String.contains?(&1, "capture flush failed"))

      assert flush_line =~ "disk_full"
    end
  end

  describe "ex-application > build_flush_callback > when generalise_fn is provided" do
    test "after add_episode_fn returns :ok, generalise_fn is called with (group_id, body)" do
      add_fn = fn _g, _b, _s, _o -> :ok end
      test_pid = self()

      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "summary"} end,
          add_episode_fn: add_fn,
          generalise_fn: fn group_id, body ->
            send(test_pid, {:generalise_called, group_id, body})
          end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)

      assert_receive {:generalise_called, "g1", body}, 500
      assert body =~ "Eli: hi"
    end

    test "when generalise_fn is nil (default), no generalise step runs" do
      add_fn = fn _g, _b, _s, _o -> :ok end

      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "summary"} end,
          add_episode_fn: add_fn
        )

      turns = [[Gralkor.Message.new("user", "hi")]]
      assert :ok = cb.("g1", "TestAgent", "Eli", nil, turns)
    end

    test "when add_episode_fn fails, generalise_fn is NOT called" do
      add_fn = fn _g, _b, _s, _o -> {:error, :disk_full} end
      test_pid = self()

      cb =
        App.build_flush_callback(nil,
          distill_fn: fn _ -> {:ok, "summary"} end,
          add_episode_fn: add_fn,
          generalise_fn: fn _group_id, _body ->
            send(test_pid, {:generalise_called})
          end
        )

      turns = [[Gralkor.Message.new("user", "hi")]]

      {:error, :disk_full} = cb.("g1", "TestAgent", "Eli", nil, turns)

      Process.sleep(50)
      refute_received {:generalise_called}
    end
  end

  describe "ex-application > generalise_fn_for_flush/0 > when :generalise_on_flush is true" do
    test "returns &Gralkor.Client.Native.generalise/2, so build_children wires it into the CaptureBuffer flush_callback" do
      System.put_env("GRALKOR_DATA_DIR", System.tmp_dir!())
      Application.put_env(:jido_gralkor, :generalise_on_flush, true)

      assert App.generalise_fn_for_flush() == (&Gralkor.Client.Native.generalise/2)

      [_python, _pool, {Gralkor.CaptureBuffer, opts}] = App.children()
      assert is_function(Keyword.fetch!(opts, :flush_callback), 5)
    end
  end

  describe "ex-application > generalise_fn_for_flush/0 > when :generalise_on_flush is false or unset (default)" do
    test "returns nil, so no generalise step runs on flush" do
      Application.delete_env(:jido_gralkor, :generalise_on_flush)
      assert App.generalise_fn_for_flush() == nil

      Application.put_env(:jido_gralkor, :generalise_on_flush, false)
      assert App.generalise_fn_for_flush() == nil
    end
  end
end
