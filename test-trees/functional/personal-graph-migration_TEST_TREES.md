Functional: personal-graph-migration (src: lib/gralkor/personal_graph_migration.ex, priv/python/personal_graph_migration.py, lib/mix/tasks/gralkor.migrate_personal.ex; functional: test/functional/personal_graph_migration_functional_test.exs)

when an application requests a private graph migration
  if operator identities are empty, blank, duplicated, non-textual, or already resolved graph names
    then migration rejects the identities before connecting to a graph
  if no explicit graph endpoint is supplied
    then migration rejects the connection before opening a default store
  if a connection deadline is not a finite positive duration
    then migration rejects the deadline before connecting to a graph
  if the persisted manifest fails its integrity check
    then migration refuses before changing any graph
  if a manifest has inconsistent identity mappings or migration phases
    then migration refuses before changing any graph

when a migration journal is prepared
  then the journal records the non-secret graph endpoint identity including host and port or Unix socket path, database, and username
  and the journal excludes graph credentials from its endpoint identity

when a journal is used with a different graph endpoint identity
  then migration refuses before mutating, applying, or rolling back any graph

when controlled server recovery explicitly supplies an endpoint rebind
  then migration validates source and target inventories, quiescence evidence, and original endpoint identity before resuming
  and migration records the rebound endpoint identity and recovered copy server run identity

when the endpoint changes without an explicit controlled recovery rebind
  then migration refuses before inspecting or mutating the restored clone

when the migration command receives an unsupported operation
  then it reports usage without connecting to a graph

when the migration command receives explicit JSON requests for a private graph
  then plan, prepare, advance, apply, and rollback return their durable graph phases

when an application migrates a consistent backup restored into a separate FalkorDB server
  then restored graph content and operational schema remain intact through migration and public recall

when an application inventories explicitly identified historical private graphs
  then the manifest preserves each operator identifier byte for byte in its old and new logical names
  and the manifest records both graph names using the existing injective physical encoding
  and the manifest reports source and target existence without creating either graph
  and the manifest inventories all node and relationship properties, UUIDs, endpoints, indexes, constraints, and configuration references
  and the manifest reports the installed Graphiti and connected FalkorDB versions

when an application prepares a private graph migration
  if a consumer Destination conflicts with the new private namespace
    then migration refuses before changing any graph
  if a consumer Lens already owns the packaged personal-chat name
    then migration refuses before changing any graph
  if an unrelated graph already occupies a target name
    then migration refuses before changing any graph
  if an explicitly identified source graph is missing
    then migration refuses without guessing a former lossy graph name
  if a source node or relationship carries an incompatible stored group identity
    then preparation refuses while records without a group identity remain preservable
  if any writer remains admitted, buffered, active, or failed during cutover
    then migration refuses before copying any graph
  if an episode claim still has an active lease
    then migration refuses before copying its graph

when an application migrates quiescent historical private graphs
  then every node and relationship group identity changes to its matching personal graph identity
  and episode, entity, community, relationship, and claim UUIDs remain equal
  and relationship endpoints and fact-to-episode references remain equal
  and immutable artefact content, embeddings, timestamps, source provenance, and Lens ownership remain equal
  and indexes and constraints remain operational with equal definitions
  and completed Reflection extraction markers remain complete
  and incomplete Reflection extraction markers remain incomplete
  and claim generations and fencing state remain equal under the new group identity
  and the original graphs remain unchanged and restorable
  and two punctuation-sensitive operator identities remain isolated through public historical recall
  and migrated historical episodes remain searchable without an active operator Lens
  when a completed Reflection invocation is replayed
    then public Reflection delivery returns the original immutable artefact
  when an incomplete Reflection invocation resumes
    then public Reflection delivery completes under its original artefact identity

when an interrupted private graph migration resumes from its persisted manifest
  then a copied graph resumes without duplicating nodes or relationships
  and an already verified target returns the same completed migration result
  if the source changed after its recorded inventory
    then migration refuses without replacing either graph
  if a recorded target contains conflicting data
    then migration refuses without replacing the conflicting target

when a private graph copy exceeds its connection deadline
  then migration returns a bounded error without retrying its uncertain copy
  if the original copy completes after the caller times out
    then a matching complete target resumes safely into public historical recall
  if the target remains absent until the graph server is recovered
    then migration refuses premature resume and rollback before safely retrying on the recovered server

when an application rolls back a private graph migration before admitting new writers
  then public historical recall through the original graph returns the original memory
  and only matching migration-owned target graphs are removed
  and a repeated rollback returns the same rolled-back result
  if a target changed after verification
    then rollback refuses without deleting the changed graph
