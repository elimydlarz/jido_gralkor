Unit: artefact (src: lib/gralkor/artefact.ex; unit: test/gralkor/artefact_test.exs)

when a consumer constructs an artefact from a stable identifier and structured payload
  then one `%Gralkor.Artefact{}` is returned
  and it contains exactly that identifier and payload

when an artefact identifier is derived from an operator, invocation, and Reflection name
  then the same ordered identity tuple always produces the same identifier
  and boundaries between identity components remain unambiguous
  and changing any identity component changes the derived identifier
