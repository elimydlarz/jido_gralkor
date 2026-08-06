defmodule Gralkor.GeneraliseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gralkor.Generalise

  defp ok_hypothesise(candidates), do: fn _prompt -> {:ok, candidates} end
  defp ok_evaluate(decisions), do: fn _prompt -> {:ok, decisions} end
  defp ok_search(facts), do: fn _partition, _query, _max -> {:ok, facts} end
  defp ok_add, do: fn _group, _body, _source, _ont, _opts -> :ok end

  defp default_opts(extras) do
    Keyword.merge(
      [
        hypothesise_fn: ok_hypothesise([]),
        search_gen_fn: ok_search([]),
        evaluate_fn: ok_evaluate([]),
        add_episode_fn: ok_add()
      ],
      extras
    )
  end

  describe "when the structured-output schema for hypothesising is requested" do
    test "then it requires the generalisations as a list of maps" do
      schema = Generalise.hypothesise_schema()
      assert schema[:generalisations][:type] == {:list, :map}
      assert schema[:generalisations][:required] == true
    end

    test "and it tells the model each entry carries content and a confidence between 0.0 and 1.0" do
      doc = Generalise.hypothesise_schema()[:generalisations][:doc]
      assert doc =~ "content"
      assert doc =~ "confidence"
      assert doc =~ "0.0-1.0"
    end
  end

  describe "when the structured-output schema for evaluating is requested" do
    test "then it requires the decisions as a list of maps" do
      schema = Generalise.evaluate_schema()
      assert schema[:decisions][:type] == {:list, :map}
      assert schema[:decisions][:required] == true
    end

    test "and it tells the model each decision carries an action, the hypothesis index, a confidence and the content to save" do
      doc = Generalise.evaluate_schema()[:decisions][:doc]
      assert doc =~ "action"
      assert doc =~ "hypothesis_index"
      assert doc =~ "confidence"
      assert doc =~ "content"
    end

    test "and it tells the model which actions are available" do
      assert Generalise.evaluate_schema()[:decisions][:doc] =~
               "save|broadens|narrows|contradicts|skip"
    end
  end

  describe "when a transcript is generalised" do
    test "then only hypothesised candidates at or above the minimum confidence reach evaluation" do
      prompt =
        evaluation_prompt([
          %{content: "xyzzy-below-threshold-unique", confidence: 0.2},
          %{content: "above", confidence: 0.7}
        ])

      assert prompt =~ "above"
      refute prompt =~ "xyzzy-below-threshold-unique"
    end

    test "and candidates reach evaluation sorted by confidence descending" do
      prompt =
        evaluation_prompt([
          %{content: "c_low", confidence: 0.4},
          %{content: "c_high", confidence: 0.9},
          %{content: "c_mid", confidence: 0.6}
        ])

      position = fn content -> :binary.match(prompt, content) |> elem(0) end
      assert position.("c_high") < position.("c_mid")
      assert position.("c_mid") < position.("c_low")
    end

    test "and the minimum confidence defaults to 0.3" do
      prompt =
        evaluation_prompt([
          %{content: "just below", confidence: 0.29},
          %{content: "exactly at", confidence: 0.3}
        ])

      assert prompt =~ "exactly at"
      refute prompt =~ "just below"
    end
  end

  describe "when a transcript is generalised > if every hypothesised candidate falls below the minimum confidence" do
    test "then nothing is persisted" do
      refute_persistence([
        %{content: "weak", confidence: 0.1},
        %{content: "vague", confidence: 0.25}
      ])
    end
  end

  describe "when a transcript is generalised > if no candidates are hypothesised at all" do
    test "then nothing is persisted" do
      refute_persistence([])
    end
  end

  describe "when evaluation decides to save a candidate" do
    test "then a new generalisation is persisted at level 0" do
      {generalisation, _body, _opts} = persisted("save", nil)
      assert generalisation.level == 0
    end

    test "and it records no generalised ids" do
      {generalisation, _body, _opts} = persisted("save", nil)
      assert generalisation.generalises == []
    end

    test "and the persisted episode body is the encoded generalisation" do
      {generalisation, body, _opts} = persisted("save", nil)
      assert {:ok, ^generalisation, _plain} = Gralkor.Generalisation.decode(body)
    end
  end

  describe "when evaluation decides a candidate broadens an existing generalisation" do
    test "then a new generalisation is persisted one level above the existing one" do
      existing = existing_generalisation(1)
      {generalisation, _body, _opts} = persisted("broadens", existing)
      assert generalisation.level == 2
    end

    test "and it records the existing generalisation's id as generalised" do
      existing = existing_generalisation(1)
      {generalisation, _body, _opts} = persisted("broadens", existing)
      assert generalisation.generalises == [existing.id]
    end

    test "and the existing generalisation is left active" do
      existing = existing_generalisation(1)
      persisted("broadens", existing)
      assert existing == existing_generalisation(1)
    end
  end

  describe "when evaluation decides a candidate narrows an existing generalisation" do
    test "then a new generalisation is persisted one level above the existing one" do
      existing = existing_generalisation(1)
      {generalisation, _body, _opts} = persisted("narrows", existing)
      assert generalisation.level == 2
    end

    test "and it records the existing generalisation's id as generalised" do
      existing = existing_generalisation(1)
      {generalisation, _body, _opts} = persisted("narrows", existing)
      assert generalisation.generalises == [existing.id]
    end

    test "and the existing generalisation is left active" do
      existing = existing_generalisation(1)
      persisted("narrows", existing)
      assert existing == existing_generalisation(1)
    end
  end

  describe "when evaluation decides a candidate contradicts an existing generalisation" do
    test "then the contradicting generalisation is persisted one level above the existing one" do
      existing = existing_generalisation(0)
      {generalisation, _body, _opts} = persisted("contradicts", existing)
      assert generalisation.level == 1
    end

    test "and it records the existing generalisation's id as generalised" do
      existing = existing_generalisation(0)
      {generalisation, _body, _opts} = persisted("contradicts", existing)
      assert generalisation.generalises == [existing.id]
    end

    test "and the existing generalisation is left in place, because the graph library owns episode identity and a generalisation's id cannot address its episode" do
      existing = existing_generalisation(0)
      persisted("contradicts", existing)
      assert existing == existing_generalisation(0)
    end
  end

  describe "when evaluation decides to skip a candidate" do
    test "then no episode is added" do
      refute_decision_persistence("skip")
    end
  end

  describe "when any decision persists a new generalisation" do
    test "then the episode write supplies no episode identifier, so the graph library mints a new episode instead of failing to find one to update" do
      {_generalisation, _body, opts} = persisted("save", nil)
      assert opts == []
    end

    test "and the generalisation's own id travels in the episode body, where it records lineage between generalisations" do
      {generalisation, body, _opts} = persisted("save", nil)
      assert body =~ generalisation.id
    end
  end

  describe "when the existing generalisation named by a decision is found among the searched generalisations" do
    test "then the new generalisation's level is one above that existing level" do
      existing = existing_generalisation(3)
      {generalisation, _body, _opts} = persisted("broadens", existing)
      assert generalisation.level == 4
    end
  end

  describe "if the existing generalisation named by a decision is not found" do
    test "then the new generalisation's level is 0" do
      {generalisation, _body, _opts} = persisted("broadens", nil, "missing")
      assert generalisation.level == 0
    end
  end

  describe "if the hypothesis model call fails" do
    test "then generalisation still returns :ok" do
      {result, _logs} = hypothesis_failure()
      assert result == :ok
    end

    test "and the failure is logged" do
      {_result, logs} = hypothesis_failure()
      assert logs =~ "generalise upstream LLM error"
      assert logs =~ ":timeout"
    end
  end

  describe "if the evaluation model call fails" do
    test "then generalisation still returns :ok" do
      {result, _persisted} = evaluation_failure()
      assert result == :ok
    end

    test "and nothing is persisted" do
      {_result, persisted?} = evaluation_failure()
      refute persisted?
    end
  end

  describe "if the search for existing generalisations fails" do
    test "then evaluation continues against an empty existing list" do
      assert search_failure_prompt() =~ "(no existing generalisations in memory)"
    end
  end

  describe "if an episode write fails" do
    test "then the failure is logged" do
      {logs, _persisted} = episode_write_failure()
      assert logs =~ "generalise persist failed"
      assert logs =~ ":disk_full"
    end

    test "and the remaining decisions are still applied" do
      {_logs, persisted} = episode_write_failure()
      assert Enum.sort(persisted) == ["first", "second"]
    end
  end

  defp evaluation_prompt(candidates) do
    evaluate_fn = fn prompt ->
      Process.put(:evaluate_prompt, prompt)
      {:ok, []}
    end

    assert :ok =
             Generalise.generalise(
               "g",
               "transcript",
               default_opts(hypothesise_fn: ok_hypothesise(candidates), evaluate_fn: evaluate_fn)
             )

    Process.get(:evaluate_prompt)
  end

  defp refute_persistence(candidates) do
    add_fn = fn _group, _body, _source, _ontology, _opts ->
      Process.put(:add_called, true)
      :ok
    end

    assert :ok =
             Generalise.generalise(
               "g",
               "transcript",
               default_opts(hypothesise_fn: ok_hypothesise(candidates), add_episode_fn: add_fn)
             )

    refute Process.get(:add_called, false)
  end

  defp existing_generalisation(level) do
    %Gralkor.Generalisation{
      id: "gen-existing",
      content: "existing",
      level: level,
      confidence: 0.8
    }
  end

  defp persisted(action, existing, existing_id \\ nil) do
    candidate = %{content: "candidate", confidence: 0.9}

    decision = %{
      hypothesis_index: 0,
      action: action,
      confidence: 0.9,
      content: candidate.content
    }

    decision =
      case {existing, existing_id, action} do
        {%Gralkor.Generalisation{id: id}, _, _} -> Map.put(decision, :existing_id, id)
        {nil, id, _} when is_binary(id) -> Map.put(decision, :existing_id, id)
        {nil, nil, "save"} -> decision
      end

    search_results = if existing, do: [Gralkor.Generalisation.encode(existing)], else: []

    add_fn = fn _group, body, _source, _ontology, opts ->
      Process.put(:persisted_body, body)
      Process.put(:persisted_opts, opts)
      :ok
    end

    assert :ok =
             Generalise.generalise(
               "g",
               "transcript",
               default_opts(
                 hypothesise_fn: ok_hypothesise([candidate]),
                 search_gen_fn: ok_search(search_results),
                 evaluate_fn: ok_evaluate([decision]),
                 add_episode_fn: add_fn
               )
             )

    body = Process.get(:persisted_body)
    {:ok, generalisation, _plain} = Gralkor.Generalisation.decode(body)
    {generalisation, body, Process.get(:persisted_opts)}
  end

  defp refute_decision_persistence(action) do
    add_fn = fn _group, _body, _source, _ontology, _opts ->
      Process.put(:add_called, true)
      :ok
    end

    decision = %{hypothesis_index: 0, action: action, confidence: 0.5, content: "candidate"}

    assert :ok =
             Generalise.generalise(
               "g",
               "transcript",
               default_opts(
                 hypothesise_fn: ok_hypothesise([%{content: "candidate", confidence: 0.5}]),
                 evaluate_fn: ok_evaluate([decision]),
                 add_episode_fn: add_fn
               )
             )

    refute Process.get(:add_called, false)
  end

  defp hypothesis_failure do
    result =
      capture_log(fn ->
        Process.put(
          :hypothesis_failure_result,
          Generalise.generalise(
            "g",
            "transcript",
            default_opts(hypothesise_fn: fn _prompt -> {:error, {:upstream_llm, :timeout}} end)
          )
        )
      end)

    {Process.get(:hypothesis_failure_result), result}
  end

  defp evaluation_failure do
    add_fn = fn _group, _body, _source, _ontology, _opts ->
      Process.put(:add_called, true)
      :ok
    end

    result =
      Generalise.generalise(
        "g",
        "transcript",
        default_opts(
          hypothesise_fn: ok_hypothesise([%{content: "candidate", confidence: 0.8}]),
          evaluate_fn: fn _prompt -> {:error, {:upstream_llm, :rate_limited}} end,
          add_episode_fn: add_fn
        )
      )

    {result, Process.get(:add_called, false)}
  end

  defp search_failure_prompt do
    evaluate_fn = fn prompt ->
      Process.put(:evaluate_prompt, prompt)
      {:ok, []}
    end

    assert :ok =
             Generalise.generalise(
               "g",
               "transcript",
               default_opts(
                 hypothesise_fn: ok_hypothesise([%{content: "candidate", confidence: 0.8}]),
                 search_gen_fn: fn _partition, _query, _max -> {:error, :search_failed} end,
                 evaluate_fn: evaluate_fn
               )
             )

    Process.get(:evaluate_prompt)
  end

  defp episode_write_failure do
    candidates = [
      %{content: "first", confidence: 0.9},
      %{content: "second", confidence: 0.8}
    ]

    decisions = [
      %{hypothesis_index: 0, action: "save", confidence: 0.9, content: "first"},
      %{hypothesis_index: 1, action: "save", confidence: 0.8, content: "second"}
    ]

    add_fn = fn _group, body, _source, _ontology, _opts ->
      {:ok, generalisation, _plain} = Gralkor.Generalisation.decode(body)
      Process.put(:persisted, [generalisation.content | Process.get(:persisted, [])])
      if generalisation.content == "first", do: {:error, :disk_full}, else: :ok
    end

    logs =
      capture_log(fn ->
        assert :ok =
                 Generalise.generalise(
                   "g",
                   "transcript",
                   default_opts(
                     hypothesise_fn: ok_hypothesise(candidates),
                     evaluate_fn: ok_evaluate(decisions),
                     add_episode_fn: add_fn
                   )
                 )
      end)

    {logs, Process.get(:persisted)}
  end
end
