Unit: reflection-journal (src: lib/gralkor/reflection/journal.ex; unit: test/gralkor/reflection/journal_test.exs)

when durable Reflection work is written and synchronized
  then reopening the journal returns the exact work under its logical completion key

when durable Reflection work is deleted and synchronized
  then reopening the journal does not return that work

when no durable journal path is configured
  then reads, writes, deletes, and close are successful no-ops
