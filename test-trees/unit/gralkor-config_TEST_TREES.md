Unit: gralkor-config (src: lib/gralkor/config.ex; unit: test/gralkor/config_test.exs)

when the FalkorDB connection is resolved
  while neither a remote configuration nor a data directory is set
    then nothing is returned, so the supervisor can start with no children
  while a data directory is set
  and no remote configuration is set
    then an embedded connection carrying that data directory is returned
    and a leading tilde in the data directory is expanded to an absolute path
  while a remote configuration carrying a host and a port is set
    then a remote connection carrying that configuration unchanged is returned
    and a supplied username and password are carried through unchanged
    while a data directory is also set
      then the remote connection is the one returned

if the remote FalkorDB configuration is not a keyword list
  then resolving the connection raises, naming the offending value

if the remote FalkorDB configuration omits its host
  then resolving the connection raises, naming the missing host

if the remote FalkorDB configuration omits its port
  then resolving the connection raises, naming the missing port

if the remote FalkorDB host is blank
  then resolving the connection raises, naming the offending value

if the remote FalkorDB port is not a positive integer
  then resolving the connection raises, naming the offending value

when a role's model override is configured as a provider and a model id joined by a colon
  then a spec carrying that provider as an atom and that model id as a string is returned
  and the returned spec is not narrowed to any particular provider, so provider support is decided where the inference clients are built
  and only the first colon separates the provider from the model id, so a model id may itself contain colons
  and the inline spec avoids a catalog lookup and unverified-model warning
  and surrounding whitespace around the provider and model id is ignored

when no model override is configured for a role
  then the Google default model spec for that role is returned

when a role's model override is configured as a blank value, including whitespace alone
  then the Google default model spec for that role is returned

if a role's model override omits the colon separator
  then resolving that role's model raises, naming the environment variable and the offending value

if a role's model override leaves the provider or the model id blank after surrounding whitespace is removed
  then resolving that role's model raises, naming the environment variable and the offending value

when the deployment-wide ontology is resolved
  while no ontology is configured
    then nothing is returned, so every write behaves as it does with no ontology declared
  while a module declared as an ontology is configured
    then that module is returned

if the configured deployment-wide ontology is a module that is not declared as an ontology
  then resolving it raises at the write boundary, naming the offending value

if the configured deployment-wide ontology is not a module
  then resolving it raises at the write boundary, naming the offending value
