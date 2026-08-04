Unit: format-transcript (src: lib/gralkor/distill.ex; unit: test/gralkor/distill_test.exs)

when turns are rendered into the transcript body written to the graph
  then user messages render as "{user_name}: {content}"
  and assistant messages render as "{agent_name}: {content}"
  and behaviour messages are dropped, so no reasoning line reaches the transcript
  and the rendered turns are joined with newlines
  and rendering is pure, accepting no LLM caller at all
  when a turn holds only behaviour messages
    then that turn contributes no lines to the transcript
  if the agent name is missing or blank
    then an argument error naming the agent name is raised
  if the user name is missing or blank
    then an argument error naming the user name is raised, because a generic user label would collapse every user into one graph node
