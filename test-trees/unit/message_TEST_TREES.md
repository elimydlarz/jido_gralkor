Unit: message (src: lib/gralkor/message.ex; unit: test/gralkor/message_test.exs)

when a canonical message is built from a role and content
  then it carries that role and that content unchanged
  where the role is `user`, `assistant`, or `behaviour`
    then the message is built, those being the three roles Gralkor branches on
  if the role is anything else
    then no message is built, an adapter having to collapse its harness's activity into one of the three first
  if the content is not a string
    then no message is built
