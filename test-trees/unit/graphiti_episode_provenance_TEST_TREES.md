Unit: Graphiti episode provenance (src: lib/gralkor/graphiti_pool.ex; unit: test/gralkor/graphiti_episode_provenance_test.exs)

when add_episode receives an originating Lens
  then the created Episodic node records that Lens by its returned episode identity

where add_episode has no originating Lens
  then no provenance update is attempted
