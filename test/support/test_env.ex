defmodule Gralkor.TestEnv do
  @moduledoc """
  Loads `KEY=VALUE` pairs from `.env` at the project root into the process
  environment, without overwriting variables already set.

  Functional tests (`test/functional/`) and any GraphitiPool/Python integration
  tests need `GOOGLE_API_KEY` to call Gemini via req_llm and via graphiti's
  bundled clients. The key lives in `.env` (gitignored) — see `.env.example`.
  """

  def load(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
        |> Enum.each(fn line ->
          case String.split(line, "=", parts: 2) do
            [k, v] ->
              k = String.trim(k)
              v = v |> String.trim() |> String.trim("\"") |> String.trim("'")
              if System.get_env(k) in [nil, ""], do: System.put_env(k, v)

            _ ->
              :ok
          end
        end)

      {:error, :enoent} ->
        :ok
    end

    bridge_gemini_to_google_api_key()
  end

  # The user keeps the Gemini credential in `GEMINI_API_KEY`; req_llm and
  # graphiti's bundled clients both want `GOOGLE_API_KEY`. Bridge if only the
  # former is set.
  defp bridge_gemini_to_google_api_key do
    case {System.get_env("GOOGLE_API_KEY"), System.get_env("GEMINI_API_KEY")} do
      {google, _} when google not in [nil, ""] -> :ok
      {_, gemini} when gemini not in [nil, ""] -> System.put_env("GOOGLE_API_KEY", gemini)
      _ -> :ok
    end
  end
end
