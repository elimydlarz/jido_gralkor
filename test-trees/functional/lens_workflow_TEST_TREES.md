Functional: Consumer Lens workflow (functional: test/functional/lens_workflow_test.exs)

given a consumer registers local, global, and generalising Lenses and mounts the plugin with defaults
  when tools add through the default and per-turn Lenses and a completed turn is flushed through primary and generalising Lenses
    then each ingestion process writes through its application-owned Lens definition
    and the complete turn is represented once in session context while both configured capture destinations receive it
  when the mounted search tool searches configured local and global targets
    then selected local and unfiltered global memory are returned together
    and an unselected local Lens and another operator's local memory remain excluded
