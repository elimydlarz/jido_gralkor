Integration: graphiti-episode-provenance (src: lib/gralkor/graphiti_pool.ex; integration: test/gralkor/graphiti_episode_provenance_test.exs)

when add_episode receives an originating Lens
  then the source description submitted to Graphiti identifies that Lens
  and no second graph mutation is attempted after Graphiti ingests the episode

where add_episode has no originating Lens
  then the original source description is submitted unchanged
