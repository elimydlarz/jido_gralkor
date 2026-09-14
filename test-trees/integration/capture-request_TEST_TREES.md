Integration: capture-request (src: lib/gralkor/capture.ex, lib/gralkor/destination.ex, lib/jido_gralkor/runtime.ex; integration: test/integration/capture_request_integration_test.exs)

when a capture request is validated
  then non-blank identity fields and canonical messages remain unchanged
  and an empty canonical message list remains valid for an empty transcript
  if a required identity field is missing or blank
    then validation identifies the rejected field
  if operator identity contains a resolved private graph name
    then validation rejects the graph name as an identity
  if messages are not canonical message records with supported roles and string content
    then validation rejects the messages
  if the route is not an explicit direct Destination or non-empty selected Lens list
    then validation rejects the route
  if a selected Destination or Lens name is blank or not text
    then validation identifies the rejected name

when a capture request resolves through its owning runtime
  then the personal Destination retains the exact operator identifier in its logical graph
  and a shared direct Destination uses that exact shared graph
  and each distinct selected Lens resolves in first-selection order
  and different Lenses sharing a Destination retain their own definitions
  and accepted Lens definitions survive later runtime replacement
  if a selected Lens only accepts whole-graph replacement
    then resolution rejects conversation capture through that Lens
  if a selected Destination or Lens is unknown or retired
    then resolution fails before any turn can be buffered
  if the owning runtime is unavailable
    then resolution fails instead of using application configuration
