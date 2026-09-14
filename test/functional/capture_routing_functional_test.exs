defmodule Gralkor.CaptureRoutingFunctionalTest do
  use ExUnit.Case, async: false

  @moduletag :functional

  alias Gralkor.Client
  alias Gralkor.Message

  setup do
    previous_client = Application.get_env(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, Gralkor.Client.Native)
    owner = self()
    start_supervised!({JidoGralkor.Runtime, owner: owner, configuration: %{destinations: [], lenses: [], reflections: []}})

    start_supervised!(
      {Gralkor.CaptureBuffer,
       flush_callback:
         Gralkor.Application.build_flush_callback(nil,
           add_episode_fn: fn group, content, source, ontology, opts ->
             send(owner, {:direct_write, group, content, source, ontology, opts})
             :ok
           end
         ),
       lens_flush_callback: Gralkor.Application.build_lens_flush_callback(),
       retries: []}
    )

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:jido_gralkor, :client, previous_client),
        else: Application.delete_env(:jido_gralkor, :client)
    end)

    :ok
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
  end
end
