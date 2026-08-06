Unit: interpret (src: lib/gralkor/interpret.ex; unit: test/gralkor/interpret_test.exs)

when facts are interpreted for a request against a conversation
  then the prompt sent to the model carries the labelled conversation messages
  and the prompt carries the request the facts were recalled for, so relevance is judged against what was asked even when the conversation never carried it
  and the prompt carries the formatted facts
  and the prompt frames retrieved facts as understandings extracted from source material rather than proven claims
  and the prompt asks for the source context, when available, to be mentioned only where natural
  and the prompt rules out confidence labels, truth adjudication, and repetitive uncertainty warnings
  and the prompt asks that conflicting retrieved facts be preserved as separate accounts rather than one being chosen as true
  and the structured-output schema requires the relevant facts as a list of strings
  and the schema instructs the model to copy each fact line verbatim, preserving every timestamp parenthetical and dropping the leading "- "
  and the schema asks for ' — ' and a one-sentence relevance reason after each copied fact
  if the agent name is missing or blank
    then an ArgumentError is raised

when the model returns relevant facts
  then the list is returned unchanged

when the model returns an empty list
  then an empty list is returned

if the model response is not a list of strings
  then Gralkor.InterpretParseFailed is raised as a failure distinct from an upstream error
  and no partial list is returned

if the model call itself fails
  then a RuntimeError naming the interpret failure is raised

when an output token budget is supplied
  then it is passed to the model call alongside the prompt so a token ceiling can reach the provider
  and the prompt instructs the model to respond within that many tokens

when no output token budget is supplied
  then a default of 2000 is passed to the model call
  and the prompt instructs the model to respond within 2000 tokens

if the output token budget is zero, negative, or not an integer
  then an ArgumentError is raised

when the interpretation context is built from messages, a request, facts, and an agent name
  then user messages render as "User: {content}"
  and assistant messages render as "{agent_name}: {content}"
  and behaviour messages render as "{agent_name}: (behaviour: {content})"
  and messages whose content is empty once trimmed are dropped
  and the context reads "Conversation context:\n{messages}\n\nRequest to answer:\n{query}\n\nMemory facts to interpret:\n{facts}"
  and message content is neither inspected nor mutated beyond whitespace trimming
  if the agent name is missing or blank
    then an ArgumentError is raised
  where no character budget is supplied
    then a default of 8000 characters governs the fit
  when the rendered messages exceed the character budget
    then the oldest messages are dropped until the context fits
    but the newest messages that fit are retained
  if even a single message on its own exceeds the character budget
    then the conversation context is left empty
    but the request and the memory facts are still included
