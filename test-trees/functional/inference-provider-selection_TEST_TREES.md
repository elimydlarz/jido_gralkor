Functional: inference-provider-selection (src: lib/gralkor/application.ex, lib/gralkor/config.ex, lib/gralkor/graphiti_pool.ex; functional: test/functional/inference_provider_selection_functional_test.exs)

when the deployment configures an inference LLM and an embedder
  then each role takes its own configured provider, accepting OpenAI and Google
  and differing role providers construct independent clients and start the memory runtime
  while the deployment configures no reranker
    then an OpenAI LLM configures OpenAI reranking with the graph library's default reranker model
    and a Google LLM configures Google reranking with the graph library's default reranker model
  while the deployment configures a reranker
    then reranking takes its own configured provider and model
  while the deployment configures LLM routes
    then each routed prompt runs on its route's provider and model
    and each unrouted prompt runs on the configured LLM
  while the deployment configures no LLM routes
    then the graph library chooses the model for its small-model prompts
  while the deployment configures LLM tuning or embedder settings
    then the memory runtime's clients receive them
  while the deployment configures no LLM tuning or embedder settings
    then the memory runtime's clients use the graph library's defaults

where the deployment configures no LLM or embedder override
  then Google configures both roles and its credential alone starts the memory runtime

where the deployment configures a blank LLM or embedder override
  then that role uses its Google default

if the deployment configures an override without both a provider and model identifier
  then startup fails before client construction
  and the failure names the environment variable
  and the failure names the rejected value

if the deployment configures LLM routes or a tuning setting that does not parse
  then startup fails before client construction
  and the failure names the environment variable
  and the failure names the rejected value

if the native memory runtime receives an unsupported provider
  then startup fails before client construction and names every model spec and the supported providers

if the native memory runtime receives an absent or blank credential
  then startup fails before client construction and names the credential and its role

where the native memory runtime does not configure a provider for any role
  then that provider's absent credential does not prevent startup

where the deployment has not opted into the native memory runtime
  then unsupported or uncredentialed provider settings do not affect startup
