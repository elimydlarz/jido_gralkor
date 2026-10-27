Unit: gralkor-config (src: lib/gralkor/config.ex; unit: test/gralkor/config_test.exs)

when the FalkorDB connection is resolved
  while neither a remote configuration nor a data directory is set
    then nothing is returned, so the supervisor can start with no children
  while a data directory is set
    while no remote configuration is set
      then an embedded connection carrying that data directory is returned
      and a leading tilde in the data directory is expanded to an absolute path
  while the data directory is blank or only whitespace
    then it counts as unset
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

when the embedded FalkorDB socket timeout is resolved
  while no timeout is configured
    then sixty thousand milliseconds is returned
  while a positive integer timeout is configured
    then that timeout is returned unchanged

if the embedded FalkorDB socket timeout is not a positive integer
  then resolving the timeout raises, naming the setting and its offending value

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

when the reranker model is resolved
  while a provider and a model id joined by a colon are configured
    then a spec carrying that provider as an atom and that model id as a string is returned
  while no reranker model is configured, or it is blank
    then nothing is returned

if the reranker model omits the colon separator or leaves the provider or the model id blank
  then resolving the reranker model raises, naming the environment variable and the offending value

when the LLM routes are resolved
  while they are configured as a JSON object keyed by prompt group or group-qualified prompt name
    then each key's route is returned carrying its model spec and the tuning it sets
  while no LLM routes are configured, or they are blank
    then no routes are returned

if the LLM routes are not a JSON object
  then resolving them raises, naming the environment variable and the offending value

if an LLM route's key names neither a prompt group nor a prompt of that group
  then resolving them raises, naming the key and the accepted prompt names

if an LLM route's model is not a provider and a model id joined by a colon
  then resolving them raises, naming the key and the offending value

if an LLM route sets a field that is neither its model nor a tuning setting
  then resolving them raises, naming the key and the field

if an LLM route's tuning value does not parse as its setting's type
  then resolving them raises, naming the key, the setting, and the offending value

when an inference tuning setting is resolved
  while it is configured
    then its value is returned parsed as that setting's type
  while it is not configured, or it is blank
    then nothing is returned

if the max tokens, embedder dimension, or embedder batch size is not a positive integer
  then resolving it raises, naming the environment variable and the offending value

if the thinking budget is not an integer of at least -1
  then resolving it raises, naming the environment variable and the offending value

if the LLM temperature is not a number
  then resolving it raises, naming the environment variable and the offending value
