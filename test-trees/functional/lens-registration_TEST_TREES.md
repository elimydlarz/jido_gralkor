Functional: lens-registration (src: lib/gralkor/lens.ex, lib/gralkor/lens/replaceable.ex; functional: test/functional/lens_registration_functional_test.exs)

when the application compatibility registry contains a valid appending or replaceable Lens
  then direct compatibility operations can select the Lens by name
  and each selected name resolves to the same application-owned Lens definition
  and the Lens uses its referenced registered Destination

where an appending Lens definition provides `write: :append`, a Destination name, and an ingestion process
  then the Lens uses its declared ingestion behaviour

where an application compatibility Lens omits its write mode
  then the Lens defaults to `write: :append`

where an appending Lens omits its ontology
  then the Lens uses jido_gralkor's built-in default ontology

if an application compatibility Lens's ontology declares a custom entity kind named `Entity`, `Episodic`, or `Community`
  then validation fails identifying the entity kind reserved by Graphiti

when an application compatibility Lens's ontology declares a custom entity kind named `Person`
  then validation accepts that entity kind

if a Lens definition retains a top-level scope or address setting
  then validation fails identifying the unsupported Lens setting

if the application compatibility Lens registry is not a list
  then validation fails naming what it found instead

if the application compatibility registry contains an invalid Lens
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
  and a removed graph-format field is identified with its Lens
