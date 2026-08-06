Functional: retry-ownership (functional: test/functional/retry_ownership_functional_test.exs)

when any failure class arises anywhere in the stack
  then exactly one layer retries it
  and no second layer retries the same class
  and every layer above the owning one derives its own timeout from that owner's worst case

when the configured inference provider rejects a call as rate-limited
  then the BEAM-side LLM client absorbs the first rejection as its own retry
  and no memory endpoint or call site retries it a second time
  and a rejection that survives the client's own handling surfaces to the caller immediately

when the configured inference provider fails a call for a reason other than rate-limiting
  then no layer retries it
  and the failure surfaces to the caller as it was returned

when the inference provider returns output that cannot be parsed into the requested structure
  then the graph library owns the retry, up to the maximum its own client sets for the configured provider
  and the parse error text is appended to the prompt of the following attempt
  and no layer above the graph library retries it

when a write to the graph, the graph driver, or an internal rendering step fails inside a capture chain
  then the capture buffer owns the retry and backs off across one, two, and four seconds
  and no layer above the capture buffer retries it

when a write to the graph, the graph driver, or an internal rendering step fails outside a capture chain
  then no layer retries it
  and the failure surfaces to the caller immediately

when the consumer's own outermost budget expires
  then the consumer owns the outcome and returns to the user without retrying
  and the expiry is logged as a warning
