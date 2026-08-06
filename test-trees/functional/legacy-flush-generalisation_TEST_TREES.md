Functional: legacy-flush-generalisation (src: lib/gralkor/application.ex, lib/gralkor/client/native.ex, lib/gralkor/generalise.ex; functional: test/functional/legacy_flush_generalisation_functional_test.exs)

where legacy generalisation on flush is enabled
  when an implicit-default captured transcript is flushed successfully
    then generalisation is started with that transcript under the capture's group without delaying the flush result
    and a generalisation failure does not change the successful flush result

where legacy generalisation on flush is disabled
  when an implicit-default captured transcript is flushed successfully
    then no generalisation is started
