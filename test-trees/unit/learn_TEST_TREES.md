Unit: learn (src: lib/gralkor/learn.ex; unit: test/gralkor/learn_test.exs)

when one reasoning turn is learned from
  then the injected learning caller is asked exactly once, that single call producing the whole record
  and the prompt renders each user message as "{user_name}: {content}"
  and the prompt renders each assistant message as "{agent_name}: {content}"
  and the prompt renders each behaviour message as "{agent_name}: (behaviour: {content})"
  and the prompt asks what was learned that enabled solving the problem
  while the learning caller returns an atom-keyed record
    then a learning record carrying the problem kind, the approach, the success flag, and the lesson is returned
  while the learning caller returns a string-keyed record
    then its string keys are normalised into a learning record carrying those same four values
    and its success flag is a boolean
  if the learning caller returns an error
    then that error is returned to the caller unchanged, never swallowed
  if the learning caller returns anything that is neither a record nor an error
    then the unexpected shape raises rather than being swallowed
  if the agent name is missing or blank
    then an argument error is raised
  if the user name is missing or blank
    then an argument error is raised, because the lesson names the human and a generic label corrupts the record

when the structured-output schema for learning is requested
  then the problem kind is a required string
  and the approach is a required string
  and the success flag is a required boolean
  and the lesson is a required string
  and the lesson field instructs the model to answer what it learned that enabled it to solve the problem
