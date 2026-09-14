defmodule Gralkor.CaptureRoutingFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Message

  setup do
    previous_client = Application.get_env(:jido_gralkor, :client)
    previous_storage = Application.get_env(:jido_gralkor, :lens_storage)
    Application.put_env(:jido_gralkor, :lens_storage, Gralkor.Lens.Storage.InMemory)
    start_supervised!(Gralkor.Lens.Storage.InMemory)
    {:ok, behavior} = Agent.start_link(fn -> :ok end)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
    owner = self()
    start_supervised!({JidoGralkor.Runtime, owner: owner, configuration: configuration()})

    start_supervised!(
      {Gralkor.CaptureBuffer,
       flush_callback:
         Gralkor.Application.build_flush_callback(nil,
           add_episode_fn: fn group, content, source, ontology, opts ->
             send(owner, {:direct_write, group, content, source, ontology, opts})

             case Agent.get(behavior, & &1) do
               :ok ->
                 :ok

               {:error, _} = error ->
                 error

               :wait ->
                 send(owner, {:write_waiting, self()})
                 receive do: (:release -> :ok)
             end
           end
         ),
       lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
       retries: []}
    )

    on_exit(fn ->
      if previous_storage,
        do: Application.put_env(:jido_gralkor, :lens_storage, previous_storage),
        else: Application.delete_env(:jido_gralkor, :lens_storage)

      if previous_client,
        do: Application.put_env(:jido_gralkor, :client, previous_client),
        else: Application.delete_env(:jido_gralkor, :client)
    end)

    %{behavior: behavior}
  end

  describe "when a caller submits a typed runtime-targeted capture request" do
    test "then a direct route writes once to the registered Destination resolved for its operator" do
      request =
        struct!(Gralkor.Capture,
          session_id: "capture-session",
          operator_id: "Owner:Case/001",
          agent_name: "Susu",
          user_name: "Eli",
          messages: [Message.new("user", "Remember teal")],
          route: {:direct, "personal"}
        )

      assert :ok = Client.capture(self(), request)
      assert :ok = Client.impl().flush_and_await(request.session_id, 1_000)

      assert_receive {:direct_write, "personal/Owner:Case/001", "Eli: Remember teal", "captured",
                      Gralkor.DefaultOntology, opts}

      assert opts[:source_kind] == :conversation
      assert opts[:writer] == :direct
      refute Keyword.has_key?(opts, :lens)
      refute_receive {:direct_write, _, _, _, _, _}
    end

    test "and a Lens route invokes each distinct selected Lens without an implicit direct write" do
      capture({:lenses, ["personal-chat", "first", "first"]}, "one")
      assert :ok = Client.impl().flush_and_await("capture-session", 1_000)
      assert Enum.map(episodes(), & &1.lens) == ["personal-chat", "first"]
      refute_receive {:direct_write, _, _, _, _, _}
    end

    test "and a Lens keeps its declared Destination and ontology" do
      capture({:lenses, ["shared"]}, "one")
      assert :ok = Client.impl().flush_and_await("capture-session", 1_000)

      assert [%{content: "Eli: one", lens: "shared"}] =
               Gralkor.Lens.Storage.InMemory.episodes("shared")

      assert episodes() == []
    end

    test "and each session binds its runtime owner, operator, agent, and user" do
      capture({:direct, "personal"}, "one")

      for {field, value} <- [operator_id: "another", agent_name: "another", user_name: "another"] do
        request = Map.put(request({:lenses, ["first"]}, "two"), field, value)
        assert_raise ArgumentError, ~r/bound/, fn -> Client.capture(self(), request) end
      end

      other_owner = spawn(fn -> receive do: (:stop -> :ok) end)

      start_supervised!({JidoGralkor.Runtime, owner: other_owner, configuration: configuration()},
        id: :other_runtime
      )

      assert_raise ArgumentError, ~r/runtime_owner/, fn ->
        Client.capture(other_owner, request({:direct, "personal"}, "two"))
      end

      send(other_owner, :stop)
      assert length(Gralkor.CaptureBuffer.turns_for("capture-session")) == 1
    end
  end

  describe "when direct and Lens routes are selected across turns in one session" do
    test "then each selected route receives only its own turns in original order" do
      capture({:direct, "personal"}, "direct first")
      capture({:lenses, ["first"]}, "lens first")
      capture({:direct, "personal"}, "direct second")
      capture({:lenses, ["first"]}, "lens second")
      assert :ok = Client.impl().flush_and_await("capture-session", 1_000)
      assert_receive {:direct_write, _, "Eli: direct first\nEli: direct second", _, _, _}
      assert [%{content: "Eli: lens first\nEli: lens second", lens: "first"}] = episodes()
    end

    test "and distinct Lens definitions sharing a Destination remain separate batches" do
      capture({:lenses, ["first", "second"]}, "shared turn")
      assert :ok = Client.impl().flush_and_await("capture-session", 1_000)
      assert Enum.map(episodes(), & &1.lens) == ["first", "second"]
    end
  end

  describe "when runtime configuration changes or its owner terminates after capture is accepted" do
    test "then buffered routes retain their captured Destination, ontology, and ingestion definitions" do
      capture({:lenses, ["first"]}, "old configuration")
      capture({:direct, "personal"}, "private")

      assert :ok =
               JidoGralkor.Runtime.replace(self(), %{
                 destinations: [],
                 lenses: [],
                 reflections: []
               })

      stop_supervised!(JidoGralkor.Runtime)
      assert :ok = Client.impl().flush_and_await("capture-session", 1_000)
      assert [%{lens: "first", content: "Eli: old configuration"}] = episodes()

      assert_receive {:direct_write, "personal/Owner:Case/001", "Eli: private", _,
                      Gralkor.DefaultOntology, _}
    end
  end

  describe "when an asynchronous flush is requested" do
    test "then it schedules work and consumes the buffered entry before completion", %{
      behavior: behavior
    } do
      Agent.update(behavior, fn _ -> :wait end)
      capture({:direct, "personal"}, "one")
      assert :ok = Client.impl().flush("capture-session")
      assert_receive {:write_waiting, worker}
      assert Gralkor.CaptureBuffer.turns_for("capture-session") == []
      send(worker, :release)
    end

    test "and shutdown waits for active and buffered capture work", %{behavior: behavior} do
      Agent.update(behavior, fn _ -> :wait end)
      capture({:direct, "personal"}, "active")
      assert :ok = Client.impl().flush("capture-session")
      assert_receive {:write_waiting, worker}
      capture({:lenses, ["first"]}, "buffered")
      task = Task.async(fn -> GenServer.stop(Gralkor.CaptureBuffer) end)
      assert Task.yield(task, 20) == nil
      send(worker, :release)
      assert :ok = Task.await(task)
      assert [%{content: "Eli: buffered"}] = episodes()
    end
  end

  describe "when a caller awaits capture flush completion" do
    test "then successful completion consumes the buffered entry" do
      capture({:direct, "personal"}, "one")
      assert :ok = Client.impl().flush_and_await("capture-session", 1_000)
      assert Gralkor.CaptureBuffer.turns_for("capture-session") == []
    end

    test "and terminal failure consumes the buffered entry", %{behavior: behavior} do
      Agent.update(behavior, fn _ -> {:error, :capture_client_4xx} end)
      capture({:direct, "personal"}, "one")

      assert {:error, :capture_client_4xx} =
               Client.impl().flush_and_await("capture-session", 1_000)

      assert Gralkor.CaptureBuffer.turns_for("capture-session") == []
    end

    test "and an await timeout preserves the buffered entry for another attempt", %{
      behavior: behavior
    } do
      Agent.update(behavior, fn _ -> :wait end)
      capture({:direct, "personal"}, "one")
      assert {:error, :timeout} = Client.impl().flush_and_await("capture-session", 20)
      assert [_] = Gralkor.CaptureBuffer.turns_for("capture-session")
      Agent.update(behavior, fn _ -> :ok end)
      assert :ok = Client.impl().flush_and_await("capture-session", 1_000)
    end
  end

  describe "when one selected capture route fails" do
    test "then remaining selected routes are still attempted", %{behavior: behavior} do
      Agent.update(behavior, fn _ -> {:error, :capture_client_4xx} end)
      capture({:direct, "personal"}, "failed")
      capture({:lenses, ["first"]}, "survives")

      assert {:error, :capture_client_4xx} =
               Client.impl().flush_and_await("capture-session", 1_000)

      assert [%{content: "Eli: survives"}] = episodes()
    end

    test "and the overall flush returns failure", %{behavior: behavior} do
      Agent.update(behavior, fn _ -> {:error, :capture_client_4xx} end)
      capture({:lenses, ["first"]}, "survives")
      capture({:direct, "personal"}, "failed")

      assert {:error, :capture_client_4xx} =
               Client.impl().flush_and_await("capture-session", 1_000)
    end
  end

  describe "when a capture route renders an empty transcript" do
    test "then no write or Lens ingestion runs" do
      for route <- [{:direct, "personal"}, {:lenses, ["first"]}] do
        assert :ok = Client.capture(self(), %{request(route, "") | messages: []})
      end

      assert :ok = Client.impl().flush_and_await("capture-session", 1_000)
      assert episodes() == []
      refute_receive {:direct_write, _, _, _, _, _}
    end
  end

  describe "if a capture request has an invalid identity, route, Destination, or selected Lens" do
    test "then capture fails before buffering any turn" do
      for {key, value} <- [
            operator_id: "",
            session_id: "",
            agent_name: nil,
            user_name: " ",
            route: {:direct, "missing"},
            route: {:direct, "operator"},
            route: {:lenses, []},
            route: {:lenses, ["operator"]},
            route: {:lenses, ["missing"]},
            route: {:lenses, [42]}
          ] do
        assert_raise ArgumentError, fn ->
          Client.capture(self(), Map.put(request({:direct, "personal"}, "one"), key, value))
        end
      end

      assert Gralkor.CaptureBuffer.turns_for("capture-session") == []
    end
  end

  describe "if a caller uses a retired positional capture adapter" do
    test "then an explicit migration error identifies the typed runtime-targeted capture request" do
      for adapter <- [Gralkor.Client.Native, Gralkor.Client.InMemory], arity <- [5, 6, 7, 8] do
        assert_raise ArgumentError, ~r/positional capture.*retired.*Gralkor.Capture/, fn ->
          apply(adapter, :capture, List.duplicate("old", arity))
        end
      end
    end
  end

  defp request(route, content) do
    %Gralkor.Capture{
      session_id: "capture-session",
      operator_id: "Owner:Case/001",
      agent_name: "Susu",
      user_name: "Eli",
      messages: [Message.new("user", content)],
      route: route
    }
  end

  defp capture(route, content), do: Client.capture(self(), request(route, content))
  defp episodes, do: Gralkor.Lens.Storage.InMemory.episodes("personal/Owner:Case/001")

  defp configuration do
    %{
      destinations: [%{name: "shared"}],
      lenses:
        Enum.map(
          ["first", "second", "shared"],
          &%{
            name: &1,
            destination: if(&1 == "shared", do: "shared", else: "personal"),
            write: :append,
            ingestion: Gralkor.Lens.Ingestion.Store
          }
        ),
      reflections: []
    }
  end
end
