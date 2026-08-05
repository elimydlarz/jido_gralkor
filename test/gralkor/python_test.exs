defmodule Gralkor.PythonTest do
  use ExUnit.Case, async: false

  alias Gralkor.Python

  describe "ex-python-runtime > orphan reap" do
    test "every redislite pid returned by the listing function is killed" do
      list_orphans = fn -> [1234, 5678] end
      killed = :ets.new(:killed, [:public, :set])
      kill_pid = fn pid -> :ets.insert(killed, {pid, true}) end

      assert :ok = Python.reap_redislite_orphans(list_orphans, kill_pid)

      assert :ets.lookup(killed, 1234) == [{1234, true}]
      assert :ets.lookup(killed, 5678) == [{5678, true}]
    end

    test "when no orphans are listed, no kills are attempted" do
      called = :counters.new(1, [])

      list_orphans = fn -> [] end

      kill_pid = fn _pid ->
        :counters.add(called, 1, 1)
        :ok
      end

      assert :ok = Python.reap_redislite_orphans(list_orphans, kill_pid)
      assert :counters.get(called, 1) == 0
    end
  end

  describe "ex-python-runtime > orphan reap > when running in remote mode (reap_orphans: false)" do
    test "the listing function is never called and no kills are attempted" do
      called = :counters.new(1, [])

      list_orphans = fn ->
        :counters.add(called, 1, 1)
        []
      end

      kill_pid = fn _pid ->
        :counters.add(called, 1, 1)
        :ok
      end

      assert {:ok, _} =
               Python.init(
                 reap_orphans: false,
                 list_orphans: list_orphans,
                 kill_pid: kill_pid,
                 uv_init: fn -> :ok end,
                 smoke_import: fn -> :ok end,
                 install_loop: false
               )

      assert :counters.get(called, 1) == 0
    end
  end

  describe "ex-python-runtime > venv init" do
    test "init/1 materialises the venv after reaping orphans and before smoke-importing" do
      order = :ets.new(:order, [:public, :ordered_set])
      seq = :counters.new(1, [])

      record = fn step ->
        :counters.add(seq, 1, 1)
        :ets.insert(order, {:counters.get(seq, 1), step})
      end

      assert {:ok, _} =
               Python.init(
                 reap_orphans: true,
                 list_orphans: fn ->
                   record.(:reap)
                   []
                 end,
                 kill_pid: fn _ -> :ok end,
                 uv_init: fn ->
                   record.(:uv_init)
                   :ok
                 end,
                 smoke_import: fn ->
                   record.(:smoke_import)
                   :ok
                 end,
                 install_loop: false
               )

      steps = order |> :ets.tab2list() |> Enum.map(fn {_, step} -> step end)
      assert steps == [:reap, :uv_init, :smoke_import]
    end

    test "init/1 stops with {:boot_failed, _} when venv init fails" do
      assert {:stop, {:boot_failed, {:uv_init, "boom"}}} =
               Python.init(
                 reap_orphans: false,
                 uv_init: fn -> {:error, {:uv_init, "boom"}} end,
                 smoke_import: fn -> :ok end,
                 install_loop: false
               )
    end
  end

  describe "ex-python-runtime > integration > Pythonx is reachable from inside the BEAM" do
    @describetag :integration

    test "importing graphiti_core succeeds" do
      assert :ok = Python.smoke_import_graphiti()
    end

    test "each supported provider's clients import" do
      assert :ok = Python.smoke_import_graphiti()

      for provider <- Gralkor.GraphitiPool.supported_providers() do
        assert :ok == Python.smoke_import_provider_clients(provider)
      end
    end
  end

  describe "ex-python-runtime > integration > GenServer boots through init/1" do
    @describetag :integration

    test "init returns {:ok, _state} after reap + smoke import" do
      {:ok, pid} =
        Python.start_link(
          name: nil,
          list_orphans: fn -> [] end,
          kill_pid: fn _ -> :ok end
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "ex-python-runtime > integration > redislite reaper kills a real process matching the argv pattern" do
    @describetag :integration

    test "spawns a fake-argv process, reaps via the default OS plumbing, confirms it's gone" do
      # `exec -a NAME ...` lets us set argv[0] without owning that path on disk
      # (no need for a real `redislite/bin/redis-server` binary). `pgrep -af`
      # matches against the full command line, including argv[0].
      port =
        Port.open(
          {:spawn_executable, System.find_executable("bash")},
          [
            :binary,
            args: ["-c", "exec -a 'fake/redislite/bin/redis-server' sleep 30"]
          ]
        )

      # Give bash a moment to exec into sleep with the spoofed argv.
      Process.sleep(200)

      # Default plumbing: list via `pgrep -af`, kill via `kill -KILL`.
      pids = list_redislite_pids()
      assert pids != [], "expected pgrep to find at least one fake redislite process"

      :ok = Python.reap_redislite_orphans(fn -> pids end, &kill_pid/1)

      # Wait briefly for SIGKILL + OS reap.
      Process.sleep(200)

      remaining = list_redislite_pids()

      assert remaining == [],
             "expected reaper to leave no matching processes; got #{inspect(remaining)}"

      # The Port's child has been SIGKILLed; closing the Port may itself raise
      # if it has already exited — that's fine, we don't care here.
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    defp list_redislite_pids do
      case System.cmd("pgrep", ["-af", "redislite/bin/redis-server"], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [pid_str | _] = String.split(line, " ", parts: 2)
            String.to_integer(pid_str)
          end)

        {_, _} ->
          []
      end
    end

    defp kill_pid(pid) do
      System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
      :ok
    end
  end
end
