Unit: actions-error-encoder-compat (unit: test/jido_gralkor/actions/error_encoder_compat_test.exs)

when any error reason our actions can return is normalised into a tool-error envelope
  then the envelope encodes to JSON without raising, so the agent server survives the failure
  and the envelope's details never hold a struct, which JSON encoding cannot serialise
  and the guarantee holds for every reason shape our actions produce, including recall deadlines, Python exception tuples, timeouts, bare atoms, and plain strings
