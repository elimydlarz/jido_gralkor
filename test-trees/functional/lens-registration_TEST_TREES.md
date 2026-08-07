Functional: lens-registration (functional: test/functional/lens_registration_functional_test.exs)

when an application registers a valid appending or replaceable Lens
  then direct callers and mounted memory plugins can select that Lens by name
  and every consumer observes the same application-owned Lens definition

where an existing Lens definition provides an ontology and ingestion process without a write mode
  then the Lens remains appending with its existing ingestion behaviour

if an application's Lens registry is not a list
  then configuration resolution raises `ArgumentError` naming what it found instead

if an application registers an invalid Lens
  then configuration resolution raises `ArgumentError` before ingestion or search begins
  and a blank Lens name is identified
  and a duplicate Lens name is identified
  and a reserved `default` or `global` Lens name is identified
  and an invalid Lens definition shape is identified
  and an invalid Lens ontology is identified with its Lens
  and an invalid Lens scope is identified with its Lens
  and an invalid Lens ingestion process is identified with its Lens
  and an invalid Lens write mode is identified with its Lens
  and a replaceable Lens without a graph format is identified with its Lens
  and a replaceable Lens with an unsupported graph format is identified with its Lens
  and a Lens definition that combines appending and replaceable write settings is identified with its Lens
