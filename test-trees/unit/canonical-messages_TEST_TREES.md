Unit: canonical-messages (src: lib/jido_gralkor/canonical.ex; unit: test/jido_gralkor/canonical_test.exs)

when a turn is rendered into canonical messages
  then the user's query becomes the opening user message exactly as given, with no envelope stripping
  and the messages run user first, then the behaviour trace in order, then the turn's outcome last
  while the query, the outcome, and the event trace are all empty
    then nothing is rendered at all, so the caller can skip the write
  while the trace holds a completed llm event that requested tools
    then it renders as a behaviour message reading `thought: …`
    while that event's content is a list of blocks rather than a string
      then the text parts are concatenated into a single thought
  while the trace holds a completed llm event that requested no tools
    then no thought behaviour message is rendered for it
  while the trace holds a completed tool event
    then it renders as a behaviour message reading `tool NAME → RESULT`
  while the trace holds events that are not memory-worthy
    then those events contribute no messages
  while the turn completed
    then the completed answer terminates the messages as the assistant message
    while the completed answer is empty
      then no assistant message is emitted
  while the turn failed
    then a terminal behaviour message reading `request failed: …` takes the place of the assistant answer
    and no assistant message is emitted
    and the user's query and the behaviour trace still precede that failure message
    while the failure reason is an error tuple
      then it is rendered by the same formatter that renders tool results
