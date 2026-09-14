defmodule Gralkor.CaptureRequestIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Gralkor.Capture
  alias Gralkor.Message
  alias JidoGralkor.Runtime

  setup do
    start_supervised!({Runtime, owner: self(), configuration: %{
      destinations: [%{name: "shared"}],
      lenses: [
        %{name: "first", destination: "personal", write: :append, ingestion: Gralkor.Lens.Ingestion.Store},
        %{name: "second", destination: "personal", write: :append, ingestion: Gralkor.Lens.Ingestion.Store},
        %{name: "replacement", destination: "shared", write: :replace_graph}
      ],
      reflections: []
    }})
    :ok
  end

  describe "when a capture request is validated" do
    test "then non-blank identity fields and canonical messages remain unchanged" do
      request = request()
      assert :ok = Capture.validate!(request)
      assert request.operator_id == "Owner:Case/001"
      assert request.messages == [%Message{role: "user", content: "hello"}]
    end

    test "and an empty canonical message list remains valid for an empty transcript" do
      assert :ok = Capture.validate!(%{request() | messages: []})
    end
  end

  describe "when a capture request is validated > if a required identity field is missing or blank" do
    test "then validation identifies the rejected field" do
      for field <- [:session_id, :operator_id, :agent_name, :user_name], value <- [nil, "", "  ", 42] do
        error = assert_raise ArgumentError, fn -> Capture.validate!(Map.put(request(), field, value)) end
        assert Exception.message(error) =~ Atom.to_string(field)
      end
    end
  end

  describe "when a capture request is validated > if operator identity contains a resolved private graph name" do
    test "then validation rejects the graph name as an identity" do
      for identity <- ["operator/owner", "personal/owner"] do
        assert_raise ArgumentError, ~r/not a resolved private graph/, fn -> Capture.validate!(%{request() | operator_id: identity}) end
      end
    end
  end

  describe "when a capture request is validated > if messages are not canonical message records with supported roles and string content" do
    test "then validation rejects the messages" do
      for messages <- [nil, %{}, [%{role: "user", content: "hello"}], [%Message{role: "system", content: "hello"}], [%Message{role: "user", content: 42}]] do
        assert_raise ArgumentError, ~r/canonical/, fn -> Capture.validate!(%{request() | messages: messages}) end
      end
    end
  end

  describe "when a capture request is validated > if the route is not an explicit direct Destination or non-empty selected Lens list" do
    test "then validation rejects the route" do
      for route <- [nil, "personal", {:lenses, []}, {:lenses, "first"}, {:direct, "personal", "extra"}] do
        assert_raise ArgumentError, ~r/route/, fn -> Capture.validate!(%{request() | route: route}) end
      end
    end
  end

  describe "when a capture request is validated > if a selected Destination or Lens name is blank or not text" do
    test "then validation identifies the rejected name" do
      for name <- [nil, "", " ", 42], route <- [{:direct, name}, {:lenses, [name]}] do
        error = assert_raise ArgumentError, fn -> Capture.validate!(%{request() | route: route}) end
        assert Exception.message(error) =~ inspect(name)
      end
    end
  end

  describe "when a capture request resolves through its owning runtime" do
    test "then the personal Destination retains the exact operator identifier in its logical graph" do
      assert [{:direct, "personal/Owner:Case/001", Gralkor.DefaultOntology}] = Capture.resolve!(self(), request())
    end

    test "and a shared direct Destination uses that exact shared graph" do
      assert [{:direct, "shared", Gralkor.DefaultOntology}] = Capture.resolve!(self(), %{request() | route: {:direct, "shared"}})
    end

    test "and each distinct selected Lens resolves in first-selection order" do
      routes = Capture.resolve!(self(), %{request() | route: {:lenses, ["second", "first", "second"]}})
      assert Enum.map(routes, fn {:lens, lens} -> lens.name end) == ["second", "first"]
    end

    test "and different Lenses sharing a Destination retain their own definitions" do
      assert [{:lens, first}, {:lens, second}] = Capture.resolve!(self(), %{request() | route: {:lenses, ["first", "second"]}})
      assert first.destination == second.destination
      assert first.name == "first"
      assert second.name == "second"
    end

    test "and accepted Lens definitions survive later runtime replacement" do
      assert [{:lens, lens}] = Capture.resolve!(self(), %{request() | route: {:lenses, ["first"]}})
      assert :ok = Runtime.replace(self(), %{destinations: [], lenses: [], reflections: []})
      assert lens.name == "first"
      assert lens.destination.name == "personal"
      assert lens.ingestion == Gralkor.Lens.Ingestion.Store
    end
  end

  describe "when a capture request resolves through its owning runtime > if a selected Lens only accepts whole-graph replacement" do
    test "then resolution rejects conversation capture through that Lens" do
      assert_raise ArgumentError, ~r/whole-graph replacement/, fn -> Capture.resolve!(self(), %{request() | route: {:lenses, ["replacement"]}}) end
    end
  end

  describe "when a capture request resolves through its owning runtime > if a selected Destination or Lens is unknown or retired" do
    test "then resolution fails before any turn can be buffered" do
      for route <- [{:direct, "unknown"}, {:direct, "operator"}, {:lenses, ["unknown"]}, {:lenses, ["operator"]}] do
        assert_raise ArgumentError, fn -> Capture.resolve!(self(), %{request() | route: route}) end
      end
    end
  end

  describe "when a capture request resolves through its owning runtime > if the owning runtime is unavailable" do
    test "then resolution fails instead of using application configuration" do
      stop_supervised!(Runtime)
      assert_raise ArgumentError, ~r/runtime/, fn -> Capture.resolve!(self(), request()) end
    end
  end

  defp request do
    %Capture{session_id: "session", operator_id: "Owner:Case/001", agent_name: "Susu", user_name: "Eli", messages: [Message.new("user", "hello")], route: {:direct, "personal"}}
  end
end
