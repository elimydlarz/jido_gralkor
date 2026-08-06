Unit: canonical-messages (src: lib/jido_gralkor/canonical.ex; unit: test/jido_gralkor/canonical_test.exs)

when a turn becomes canonical messages
  then the user's query opens them unchanged
  and the messages run user first, then the behaviour trace in order, then the turn's outcome last
  while query, outcome, and trace are empty
    then nothing is rendered at all, so the caller can skip the write
  while a tool-requesting llm event completes
    then it renders as a behaviour message reading `thought: …`
    while its content is blocks
      then the text parts form one thought
  while an llm event completes without requesting tools
    then no thought behaviour message is rendered for it
  while a tool event completes
    then it renders as a behaviour message reading `tool NAME → RESULT`
    while it carries no result
      then it renders as `tool NAME` alone, rather than as an arrow pointing at nothing
  while events are not memory-worthy
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
