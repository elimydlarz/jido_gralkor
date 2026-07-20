Functional: lens-registration (functional: test/functional/lens_registration_functional_test.exs)

when an application registers a valid Lens
  then direct callers and mounted memory plugins can select that Lens by name
  and every consumer observes the same application-owned Lens definition

if an application registers an invalid Lens
  then configuration resolution raises `ArgumentError` before ingestion or search begins
    where the Lens name is blank
      then the error identifies the invalid name
    where the Lens name duplicates another registered Lens
      then the error identifies the duplicate name
    where the Lens name is reserved as `default` or `global`
      then the error identifies the reserved name
    where the Lens definition has an invalid shape
      then the error identifies the invalid definition
    where the Lens ontology is invalid
      then the error identifies the Lens and invalid ontology
    where the Lens scope is invalid
      then the error identifies the Lens and invalid scope
    where the Lens ingestion process is invalid
      then the error identifies the Lens and invalid ingestion process
