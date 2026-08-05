defmodule Gralkor.RemoteFalkorDbJourneyTest do
  @moduledoc """
  End-to-end functional test for the remote FalkorDB path: real PythonX
  runtime, real graphiti-core, real network FalkorDB
  reached via `falkordb.asyncio.FalkorDB(host:, port:, ...)`. Mirrors
  `jido_memory_journey_test.exs` but proves the `{:remote, kw}` branch
  of `Gralkor.GraphitiPool.default_construct_falkor_db/1`.

  Reifies `test-trees/journey/remote-falkordb-journey_TEST_TREES.md`.

  Requires `DEEPSEEK_API_KEY` (for Elixir-side req_llm calls) and
  `GOOGLE_API_KEY` (for graphiti's Python-side Gemini clients), plus
  `FALKORDB_TEST_HOST` / `FALKORDB_TEST_PORT` to be set (e.g.
  `docker run -p 6380:6379 falkordb/falkordb`). Missing prerequisites
  surface as a test failure, not a skip.
  """

  use ExUnit.Case, async: false

  alias Gralkor.CaptureBuffer
  alias Gralkor.Client
  alias Gralkor.Client.Native
  alias Gralkor.GraphitiPool
  alias Gralkor.Message

  @moduletag :journey
  @moduletag timeout: 300_000

  setup_all do
    Application.put_env(:jido_gralkor, :recall_deadline_ms, 60_000)
    on_exit(fn -> Application.delete_env(:jido_gralkor, :recall_deadline_ms) end)

    original_client = Application.get_env(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)

    on_exit(fn ->
      case original_client do
        nil -> Application.delete_env(:jido_gralkor, :client)
        mod -> Application.put_env(:jido_gralkor, :client, mod)
      end
    end)

    host = System.fetch_env!("FALKORDB_TEST_HOST")
    port = System.get_env("FALKORDB_TEST_PORT", "6379") |> String.to_integer()

    falkordb_kw =
      [host: host, port: port]
      |> maybe_put(:username, System.get_env("FALKORDB_TEST_USERNAME"))
      |> maybe_put(:password, System.get_env("FALKORDB_TEST_PASSWORD"))
      |> Keyword.put(:ssl, System.get_env("FALKORDB_TEST_SSL") in ["true", "1", "yes"])

    {:ok, _python} = start_supervised({Gralkor.Python, [reap_orphans: false]})

    {:ok, _pool} =
      start_supervised(
        {GraphitiPool,
         [
           falkordb_spec: {:remote, falkordb_kw},
           llm_model: Gralkor.Config.llm_model(),
           embedder_model: Gralkor.Config.embedder_model(),
           interpret_fn: Native.interpret_callback(),
           warmup: false
         ]}
      )

    flush_callback =
      Gralkor.Application.build_flush_callback({:remote, falkordb_kw}, learn_fn: &Native.learn/3)

    {:ok, _buffer} = start_supervised({CaptureBuffer, [flush_callback: flush_callback]})

    %{
      group_id: "remote_journey_#{System.unique_integer([:positive])}",
      baseline_redislite_pids: list_redislite_pids()
    }
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, _key, ""), do: kw
  defp maybe_put(kw, key, v), do: Keyword.put(kw, key, v)

  describe "ex-remote-falkordb-journey > round-trip" do
    test "memory_add stores a fact, recall surfaces it under the same group_id", %{
      group_id: group_id
    } do
      :ok =
        Client.impl().memory_add(
          group_id,
          "Eli works at Anthropic in Sydney. He prefers concise technical explanations over verbose ones.",
          "manual",
          nil
        )

      session_id = "session_#{System.unique_integer([:positive])}"

      assert {:ok, block} =
               Client.impl().recall(group_id, "TestAgent", session_id, "Where does Eli work?")

      assert block =~ ~r/<gralkor-memory trust="untrusted">/
      assert block =~ "</gralkor-memory>"

      lower = String.downcase(block)

      assert lower =~ "anthropic" or lower =~ "sydney",
             "expected recall to surface a fact about Eli's employer or location; got: #{block}"
    end
  end

  describe "ex-remote-falkordb-journey > flush_and_await (remote)" do
    test "captured turns become recallable once flush_and_await returns :ok", %{
      group_id: group_id
    } do
      session_id = "session_#{System.unique_integer([:positive])}"

      :ok =
        Client.impl().capture(session_id, group_id, "TestAgent", "Eli", [
          Message.new(
            "user",
            "Important context: Eli's favourite colour is teal, and Eli drives a blue Subaru Outback."
          ),
          Message.new(
            "assistant",
            "Noted — Eli's favourite colour is teal and Eli drives a blue Subaru Outback."
          )
        ])

      :ok = Client.impl().flush_and_await(session_id, 60_000)

      Process.sleep(45_000)

      lookup_session = "lookup_#{System.unique_integer([:positive])}"

      assert {:ok, block} =
               Client.impl().recall(
                 group_id,
                 "TestAgent",
                 lookup_session,
                 "What car does Eli drive?"
               )

      lower = String.downcase(block)

      assert lower =~ "subaru" or lower =~ "outback",
             "expected recall to surface a fact about the car; got: #{block}"
    end
  end

  describe "ex-remote-falkordb-journey > no local redis-server is spawned" do
    test "no NEW redislite/bin/redis-server child appeared while the test ran (only orphans from prior embedded-mode runs are tolerated)",
         %{baseline_redislite_pids: baseline} do
      now = list_redislite_pids()
      new_pids = now -- baseline

      assert new_pids == [],
             "expected no new redislite redis-server processes in remote mode; baseline=#{inspect(baseline)} now=#{inspect(now)} new=#{inspect(new_pids)}"
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
end
