Functional: inference-provider-selection (functional: test/functional/inference_provider_selection_functional_test.exs)

when the deployment configures an inference LLM and an embedder
  then each role takes its own configured provider, accepting OpenAI and Google
  and an OpenAI LLM configures OpenAI reranking
  and a Google LLM configures Google reranking
  and differing role providers construct independent clients and start the memory runtime
  and an OpenAI LLM that rejects `minimal` receives `none` explicitly instead of the graph library's default

where the deployment configures no LLM or embedder override
  then Google configures both roles and its credential alone starts the memory runtime

where the deployment configures a blank LLM or embedder override
  then that role uses its Google default

if the deployment configures an override without both a provider and model identifier
  then startup fails before client construction
  and the failure names the environment variable
  and the failure names the rejected value

if the native memory runtime receives an unsupported provider
  then startup fails before client construction and names both model specs and the supported providers

if the native memory runtime receives an absent or blank credential
  then startup fails before client construction and names the credential and its role

where the native memory runtime does not configure a provider for either role
  then that provider's absent credential does not prevent startup

where the deployment has not opted into the native memory runtime
  then unsupported or uncredentialed provider settings do not affect startup
