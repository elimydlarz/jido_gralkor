defmodule Gralkor.PersonalGraphMigrationFunctionalTest do
  use ExUnit.Case, async: false

  alias Gralkor.PersonalGraphMigration

  @moduletag :functional
  @moduletag timeout: 120_000

  setup_all do
    directory = Path.join(System.tmp_dir!(), "personal-migration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    {server, globals} =
      Pythonx.eval(
        """
        from redislite import Redis
        from falkordb import FalkorDB
        server = Redis(dbfilename=path.decode(), serverconfig={'port': 0})
        database = FalkorDB(unix_socket_path=server.socket_file)
        server
        """,
        %{"path" => Path.join(directory, "fixture.rdb")}
      )

    {socket, _} = Pythonx.eval("server.socket_file", %{"server" => server})

    on_exit(fn ->
      Pythonx.eval("server.shutdown(save=False, now=True, force=True)", %{"server" => server})
      File.rm_rf!(directory)
    end)

    %{connection: [unix_socket_path: Pythonx.decode(socket)], database: globals["database"], directory: directory}
  end

  describe "when an application inventories explicitly identified historical private graphs" do
    test "then the manifest preserves each operator identifier byte for byte in its old and new logical names", context do
      identifiers = ["owner", "dashboard:ABC-123", "a/b", "a_b", "CaseSensitive"]

      assert {:ok, manifest} = PersonalGraphMigration.plan(context.connection, identifiers, %{})

      assert Enum.map(manifest["graphs"], &{&1["source_logical"], &1["target_logical"]}) ==
               Enum.map(identifiers, &{"operator/" <> &1, "personal/" <> &1})
    end
  end
end
