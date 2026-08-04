Unit: actions-error-encoder-compat (unit: test/jido_gralkor/actions/error_encoder_compat_test.exs)

when any error reason our actions can return is normalised into a tool-error envelope
  then the envelope encodes to JSON without raising, so the agent server survives the failure
  and the envelope's details never hold a struct, which JSON encoding cannot serialise
  while the reason is a recall deadline, a Python exception tuple, a timeout, a bare atom, or a plain string
    then that reason is covered by the same encoding guarantee
