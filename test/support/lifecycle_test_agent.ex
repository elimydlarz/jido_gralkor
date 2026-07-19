defmodule JidoGralkor.LifecycleTestAgent do
  @moduledoc false
  use Jido.Agent,
    name: "lifecycle_test_agent",
    description:
      "Minimal agent used to exercise JidoGralkor.Lifecycle inside a real Jido.AgentServer.",
    schema: []
end

defmodule JidoGralkor.LifecycleTestJido do
  @moduledoc false
  use Jido, otp_app: :jido_gralkor
end
