Functional: lens-registration (src: lib/gralkor/lens.ex, lib/gralkor/lens/replaceable.ex; functional: test/functional/lens_registration_functional_test.exs)

when an agent's runtime configuration contains a valid appending or replaceable Lens
  then that agent's direct and mounted memory operations can select the Lens by name
  and those operations observe the same agent-owned Lens definition
  and the Lens uses its referenced registered Destination

where an appending Lens definition provides `write: :append`, a Destination name, and an ingestion process
  then the Lens uses its declared ingestion behaviour

where an appending Lens omits its ontology
  then the Lens uses jido_gralkor's built-in default ontology

if a Lens definition retains a top-level scope or address setting
  then validation fails identifying the unsupported Lens setting

if an agent's runtime Lens collection is not a list
  then validation fails naming what it found instead

if an agent's runtime configuration contains an invalid Lens
  then validation fails before ingestion or search begins
  and a blank Lens name is identified
  and a Lens name containing the reserved provenance delimiter ` [lens: ` is identified
  and a duplicate Lens name is identified
  and a reserved `operator` or `global` Lens name is identified
  and the retired `default` Lens name identifies `operator` as its replacement
  and an invalid Lens definition shape is identified
  and a missing or unknown Lens Destination is identified with its Lens
  and an invalid Lens ontology is identified with its Lens
  and an invalid Lens ingestion process is identified with its Lens
  and an invalid Lens write mode is identified with its Lens
  and a Lens definition that combines appending and replaceable write settings is identified with its Lens
