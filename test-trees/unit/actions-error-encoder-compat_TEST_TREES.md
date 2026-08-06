Unit: actions-error-encoder-compat (unit: test/jido_gralkor/actions/error_encoder_compat_test.exs)

when an action error is normalised into a tool-error envelope
  then the envelope encodes to JSON without raising
  and its details hold no struct
  and every produced reason shape is covered
