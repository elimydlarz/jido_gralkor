defmodule Gralkor.Application do
  @moduledoc false

  use Application

  require Logger

  alias Gralkor.AgentLearning
  alias Gralkor.CaptureBuffer
  alias Gralkor.Client.Native
  alias Gralkor.Config
  alias Gralkor.Distill
  alias Gralkor.GraphitiPool
  alias Gralkor.Ingest

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: Gralkor.Supervisor)
  end

  @doc false
  def children do
    cond do
      Application.get_env(:jido_gralkor, :client) == Gralkor.Client.InMemory ->
        []

      true ->
        case Config.falkordb_spec() do
          nil -> []
          spec -> build_children(spec)
        end
    end
  end

  defp build_children(spec) do
    remote? = match?({:remote, _}, spec)

    [
      {Gralkor.Python, [reap_orphans: not remote?]},
      {GraphitiPool,
       [
         falkordb_spec: spec,
         llm_model: Config.llm_model(),
         embedder_model: Config.embedder_model(),
         interpret_fn: Native.interpret_callback()
       ]},
      {CaptureBuffer,
       [
         flush_callback:
           build_flush_callback(spec,
             generalise_fn: generalise_fn_for_flush(),
             learn_fn: &Native.learn/3
           ),
         lens_flush_callback: build_lens_flush_callback()
       ]}
    ]
  end

  @doc false
  def generalise_fn_for_flush do
    if Application.get_env(:jido_gralkor, :generalise_on_flush, false) do
      &Native.generalise/2
    end
  end

  @doc false
  def build_flush_callback(_config, deps \\ []) do
    add_episode_fn =
      Keyword.get(deps, :add_episode_fn, fn group_id, content, source, ontology, opts ->
        GraphitiPool.add_episode(GraphitiPool, group_id, content, source, ontology, opts)
      end)

    generalise_fn = Keyword.get(deps, :generalise_fn)
    learn_fn = Keyword.get(deps, :learn_fn)

    fn group_id, agent_name, user_name, ontology, turns ->
      body = Distill.format_transcript(turns, agent_name, user_name)

      cond do
        body == "" ->
          write_learnings(
            turns,
            group_id,
            ontology,
            agent_name,
            user_name,
            learn_fn,
            add_episode_fn
          )

        true ->
          t0 = System.monotonic_time(:millisecond)
          result = add_episode_fn.(group_id, body, "captured", ontology, [])
          ms = System.monotonic_time(:millisecond) - t0

          case result do
            :ok ->
              Logger.info(
                "[gralkor] capture flushed — group:#{group_id} bodyChars:#{String.length(body)} #{ms}ms"
              )

            {:error, reason} ->
              Logger.warning(
                "[gralkor] capture flush failed — group:#{group_id} #{inspect(reason)} (retrying)"
              )
          end

          if Application.get_env(:jido_gralkor, :test, false),
            do: Logger.info("[gralkor] [test] capture flush body: #{body}")

          case result do
            :ok ->
              with :ok <-
                     write_learnings(
                       turns,
                       group_id,
                       ontology,
                       agent_name,
                       user_name,
                       learn_fn,
                       add_episode_fn
                     ) do
                if generalise_fn, do: Task.start(fn -> generalise_fn.(group_id, body) end)
                :ok
              end

            {:error, _} = err ->
              err
          end
      end
    end
  end

  @doc false
  def build_lens_flush_callback(deps \\ []) do
    ingest_fn = Keyword.get(deps, :ingest_fn, &Gralkor.Client.ingest/1)

    fn operator_id, agent_name, user_name, lens, turns ->
      transcript = Distill.format_transcript(turns, agent_name, user_name)

      ingest_fn.(%Ingest{
        operator_id: operator_id,
        lens: lens,
        content: transcript,
        source_description: "captured"
      })
    end
  end

  # Learning: every turn becomes a separate AgentLearning episode in the same
  # group_id. Fail-fast — a learn_fn error, a learning-write error, or any raise
  # propagates out so the CaptureBuffer retry/backoff owns recovery; nothing is
  # swallowed. Runs in append order, only on a path that returns :ok.
  defp write_learnings(_turns, _group_id, _ontology, _agent, _user, nil, _add_episode_fn), do: :ok

  defp write_learnings(turns, group_id, ontology, agent_name, user_name, learn_fn, add_episode_fn) do
    # Learning writes carry the plugin's Learning custom entity type (merged onto
    # the consumer ontology by GraphitiPool.add_episode via this opt) so graphiti's
    # extractor emits Learning-typed nodes and SearchFilters(node_labels: ["Learning"])
    # (ex-recall) returns them. The "captured" transcript write keeps the raw ontology.
    Enum.reduce_while(turns, :ok, fn msgs, :ok ->
      case learn_fn.(msgs, agent_name, user_name) do
        {:ok, %AgentLearning{} = learning} ->
          case add_episode_fn.(
                 group_id,
                 AgentLearning.to_episode(learning),
                 "learning",
                 ontology,
                 merge_learning_entity: true
               ) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end
end
