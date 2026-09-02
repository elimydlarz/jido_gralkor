Functional: lens-registration (src: lib/gralkor/lens.ex, lib/gralkor/lens/replaceable.ex; functional: test/functional/lens_registration_functional_test.exs)

when an application registers a valid appending or replaceable Lens
  then direct callers and mounted memory plugins can select that Lens by name
  and every consumer observes the same application-owned Lens definition
  and the Lens uses its referenced registered Destination

where an appending Lens definition provides a Destination name and ingestion process without a write mode
  then the Lens remains appending with its existing ingestion behaviour

where an appending Lens omits its ontology
  then the Lens uses jido_gralkor's built-in default ontology

if an existing Lens definition retains a top-level scope or address setting
  then configuration resolution raises `ArgumentError` identifying the unsupported Lens setting

if an application's Lens registry is not a list
  then configuration resolution raises `ArgumentError` naming what it found instead

if an application registers an invalid Lens
  then configuration resolution raises `ArgumentError` before ingestion or search begins
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
  and a replaceable Lens without a graph format is identified with its Lens
  and a replaceable Lens with an unsupported graph format is identified with its Lens
  and a Lens definition that combines appending and replaceable write settings is identified with its Lens
