defmodule Gralkor.GeneraliseTest do
  use ExUnit.Case, async: true

  require Logger

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

  describe "ex-generalise > hypothesise" do
    test "when the LLM returns no candidates, nothing is persisted" do
      add_fn = fn _g, _b, _s, _ont, _opts ->
        Process.put(:add_episode_called, true)
        :ok
      end

      assert :ok =
               Generalise.generalise(
                 "g",
                 "some transcript",
                 default_opts(hypothesise_fn: ok_hypothesise([]), add_episode_fn: add_fn)
               )

      refute Process.get(:add_episode_called, false)
    end

    test "candidates below min_confidence are dropped" do
      below = [
        %{content: "weak pattern", confidence: 0.1},
        %{content: "vague preference", confidence: 0.25}
      ]

      assert :ok =
               Generalise.generalise(
                 "g",
                 "some transcript",
                 default_opts(hypothesise_fn: ok_hypothesise(below), min_confidence: 0.3)
               )

      refute Process.get(:add_episode_called, false)
    end

    test "only candidates at or above min_confidence are evaluated" do
      mixed = [
        %{content: "xyzzy-below-threshold-unique", confidence: 0.2},
        %{content: "above", confidence: 0.7}
      ]

      eval_fn = fn prompt ->
        assert prompt =~ "above"
        refute prompt =~ "xyzzy-below-threshold-unique"
        {:ok, []}
      end

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(mixed),
                   evaluate_fn: eval_fn,
                   min_confidence: 0.3
                 )
               )
    end

    test "candidates are sorted by confidence descending before evaluation" do
      candidates = [
        %{content: "c_low", confidence: 0.4},
        %{content: "c_high", confidence: 0.9},
        %{content: "c_mid", confidence: 0.6}
      ]

      eval_fn = fn prompt ->
        pos = fn s -> :binary.match(prompt, s) |> elem(0) end
        assert pos.("c_high") < pos.("c_mid")
        assert pos.("c_mid") < pos.("c_low")
        {:ok, []}
      end

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(hypothesise_fn: ok_hypothesise(candidates), evaluate_fn: eval_fn)
               )
    end
  end

  describe "ex-generalise > evaluate > save" do
    test "a save decision persists a new generalisation at level 0" do
      candidates = [%{content: "User prefers dark mode", confidence: 0.85}]

      decisions = [
        %{
          hypothesis_index: 0,
          action: "save",
          confidence: 0.85,
          content: "User prefers dark mode"
        }
      ]

      add_fn = fn _group, body, _source, _ont, opts ->
        assert body =~ "User prefers dark mode"
        assert body =~ "GEN|v1|"

        {:ok, gen, _plain} = Gralkor.Generalisation.decode(body)
        assert gen.level == 0
        assert gen.confidence == 0.85
        assert gen.generalises == []
        assert opts == []
        :ok
      end

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
    end
  end

  describe "ex-generalise > evaluate > broadens" do
    test "a broadens decision creates a new generalisation with level = existing.level + 1" do
      existing_gen = %Gralkor.Generalisation{
        id: "gen-existing-1",
        content: "User prefers dark mode in VS Code",
        level: 1,
        confidence: 0.8
      }

      candidates = [%{content: "User prefers dark mode across all editors", confidence: 0.9}]

      decisions = [
        %{
          hypothesis_index: 0,
          action: "broadens",
          confidence: 0.9,
          content: "User prefers dark mode across all editors",
          existing_id: "gen-existing-1"
        }
      ]

      add_fn = fn _group, body, _source, _ont, opts ->
        {:ok, gen, _plain} = Gralkor.Generalisation.decode(body)
        assert gen.level == 2
        assert gen.generalises == ["gen-existing-1"]
        assert opts == []
        :ok
      end

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   search_gen_fn: ok_search([Gralkor.Generalisation.encode(existing_gen)]),
                   evaluate_fn: ok_evaluate(decisions),
                   add_episode_fn: add_fn
                 )
               )
    end
  end

  describe "ex-generalise > evaluate > narrows" do
    test "a narrows decision creates a new generalisation with level = existing.level + 1" do
      existing_gen = %Gralkor.Generalisation{
        id: "gen-broad-1",
        content: "User likes music",
        level: 0,
        confidence: 0.7
      }

      candidates = [%{content: "User likes 1950s jazz", confidence: 0.95}]

      decisions = [
        %{
          hypothesis_index: 0,
          action: "narrows",
          confidence: 0.95,
          content: "User likes 1950s jazz",
          existing_id: "gen-broad-1"
        }
      ]

      add_fn = fn _group, body, _source, _ont, opts ->
        {:ok, gen, _plain} = Gralkor.Generalisation.decode(body)
        assert gen.level == 1
        assert gen.generalises == ["gen-broad-1"]
        assert opts == []
        :ok
      end

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   search_gen_fn: ok_search([Gralkor.Generalisation.encode(existing_gen)]),
                   evaluate_fn: ok_evaluate(decisions),
                   add_episode_fn: add_fn
                 )
               )
    end
  end

  describe "ex-generalise > evaluate > contradicts" do
    test "a contradicts decision saves the new generalisation one level above and leaves the existing one in place" do
      existing_gen = %Gralkor.Generalisation{
        id: "gen-outdated",
        content: "User dislikes notifications",
        level: 0,
        confidence: 0.6
      }

      candidates = [
        %{
          content: "User finds notifications helpful for time-sensitive updates",
          confidence: 0.88
        }
      ]

      decisions = [
        %{
          hypothesis_index: 0,
          action: "contradicts",
          confidence: 0.88,
          content: "User finds notifications helpful for time-sensitive updates",
          existing_id: "gen-outdated"
        }
      ]

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   search_gen_fn: ok_search([Gralkor.Generalisation.encode(existing_gen)]),
                   evaluate_fn: ok_evaluate(decisions),
                   add_episode_fn: fn _partition, body, _source, _ontology, opts ->
                     {:ok, generalisation, _plain} = Gralkor.Generalisation.decode(body)
                     assert opts[:uuid] == generalisation.id
                     :ok
                   end,
                   remove_episode_fn: fn _partition, uuid ->
                     Process.put(:remove_called, true)
                     assert uuid == "gen-outdated"
                     :ok
                   end
                 )
               )

      assert Process.get(:remove_called, false)
    end
  end

  describe "ex-generalise > evaluate > skip" do
    test "a skip decision does not persist anything" do
      candidates = [%{content: "Some weak pattern", confidence: 0.5}]

      decisions = [
        %{hypothesis_index: 0, action: "skip", confidence: 0.5, content: "Some weak pattern"}
      ]

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   evaluate_fn: ok_evaluate(decisions),
                   add_episode_fn: fn _g, _b, _s, _ont, _opts ->
                     Process.put(:add_called, true)
                     :ok
                   end
                 )
               )

      refute Process.get(:add_called, false)
    end
  end

  describe "ex-generalise > persistence identity" do
    test "whenever any decision persists a new generalisation, add_episode receives its encoded id as uuid" do
      candidates = [%{content: "User prefers dark mode", confidence: 0.85}]

      decisions = [
        %{
          hypothesis_index: 0,
          action: "save",
          confidence: 0.85,
          content: "User prefers dark mode"
        }
      ]

      add_fn = fn _group, body, _source, _ontology, opts ->
        {:ok, generalisation, _plain} = Gralkor.Generalisation.decode(body)
        assert opts[:uuid] == generalisation.id
        :ok
      end

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
    end
  end

  describe "ex-generalise > error handling" do
    test "when hypothesise LLM fails, generalise returns :ok (best-effort)" do
      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: fn _prompt -> {:error, {:upstream_llm, :timeout}} end
                 )
               )
    end

    test "when evaluate LLM fails, generalise returns :ok (best-effort)" do
      candidates = [%{content: "test", confidence: 0.8}]

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   evaluate_fn: fn _prompt -> {:error, {:upstream_llm, :rate_limited}} end
                 )
               )
    end

    test "when search fails for a hypothesis, it continues with empty existing list" do
      candidates = [%{content: "test", confidence: 0.8}]
      decisions = [%{hypothesis_index: 0, action: "save", confidence: 0.8, content: "test"}]

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   search_gen_fn: fn _p, _q, _m -> {:error, :search_failed} end,
                   evaluate_fn: ok_evaluate(decisions)
                 )
               )
    end

    test "when add_episode fails, it logs and continues" do
      candidates = [%{content: "test", confidence: 0.8}]
      decisions = [%{hypothesis_index: 0, action: "save", confidence: 0.8, content: "test"}]

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   evaluate_fn: ok_evaluate(decisions),
                   add_episode_fn: fn _g, _b, _s, _ont, _opts -> {:error, :disk_full} end
                 )
               )
    end
  end

  describe "ex-generalise > level calculation" do
    test "level is max child level + 1 via existing_by_id lookup" do
      existing_gen = %Gralkor.Generalisation{
        id: "gen-l0",
        content: "base",
        level: 3,
        confidence: 0.9
      }

      candidates = [%{content: "broader", confidence: 0.9}]

      decisions = [
        %{
          hypothesis_index: 0,
          action: "broadens",
          confidence: 0.9,
          content: "broader",
          existing_id: "gen-l0"
        }
      ]

      add_fn = fn _group, body, _source, _ont, _opts ->
        {:ok, gen, _plain} = Gralkor.Generalisation.decode(body)
        assert gen.level == 4
        :ok
      end

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   search_gen_fn: ok_search([Gralkor.Generalisation.encode(existing_gen)]),
                   evaluate_fn: ok_evaluate(decisions),
                   add_episode_fn: add_fn
                 )
               )
    end

    test "when existing_id is not found, level defaults to 0" do
      candidates = [%{content: "test", confidence: 0.8}]

      decisions = [
        %{
          hypothesis_index: 0,
          action: "broadens",
          confidence: 0.8,
          content: "test",
          existing_id: "nonexistent"
        }
      ]

      add_fn = fn _group, body, _source, _ont, _opts ->
        {:ok, gen, _plain} = Gralkor.Generalisation.decode(body)
        assert gen.level == 0
        :ok
      end

      assert :ok =
               Generalise.generalise(
                 "g",
                 "transcript",
                 default_opts(
                   hypothesise_fn: ok_hypothesise(candidates),
                   search_gen_fn: ok_search([]),
                   evaluate_fn: ok_evaluate(decisions),
                   add_episode_fn: add_fn
                 )
               )
    end
  end
end
