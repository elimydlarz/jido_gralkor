Unit: generalisation (src: lib/gralkor/generalisation.ex; unit: test/gralkor/generalisation_test.exs)

when a generalisation is built without its optional fields
  then the list of ids it generalises defaults to empty
  and its creation timestamp defaults to nil

when a generalisation is encoded
  then the first line is a "GEN|v1|" prefix followed by JSON metadata
  and the free-text content follows on the lines after it
  and the metadata carries the id, the level, the confidence, and the ids generalised
  where the generalisation generalises nothing
    then the metadata records an empty list of generalised ids

when a string carrying the "GEN|v1|" prefix is decoded
  then the generalisation and its plain content are returned
  and the id, level, confidence, and generalised ids round-trip the encoded values
  and the plain content is trimmed of leading and trailing whitespace
  where the content spans several lines
    then every line after the first is preserved as plain content
  if the JSON metadata is malformed
    then GeneralisationParseFailed is raised
  if the id, the level, or the confidence is missing from the metadata
    then GeneralisationParseFailed is raised

when a string without the "GEN|v1|" prefix is decoded
  then {:error, :not_a_generalisation} is returned

when an empty string is decoded
  then {:error, :not_a_generalisation} is returned
