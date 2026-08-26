defmodule Gralkor.TestEnv do
  @moduledoc """
  Loads `KEY=VALUE` pairs from `.env` at the project root into the process
  environment, without overwriting variables already set.

  Graphiti-backed functional tests and GraphitiPool/Python integration tests need
  provider credentials for graphiti's bundled clients. Keys live in `.env`
  (gitignored) — see `.env.example`.
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
    ensure_placeholder_provider_credentials()
  end

  # `Gralkor.GraphitiPool` refuses to start when the credential for a provider a
  # configured model spec selects is absent, so every test that starts a pool
  # needs one present — including the deterministic ones, which stub client
  # construction and never reach a provider. Placeholders are set only when the
  # variable is genuinely absent, so a real key loaded from `.env` above always
  # wins and the functional suites keep calling real providers.
  @placeholder "test-placeholder-not-a-real-credential"

  defp ensure_placeholder_provider_credentials do
    Enum.each(["GOOGLE_API_KEY", "OPENAI_API_KEY"], fn var ->
      if System.get_env(var) in [nil, ""], do: System.put_env(var, @placeholder)
    end)
  end

  # The user keeps the Gemini credential in `GEMINI_API_KEY`; graphiti's bundled
  # clients want `GOOGLE_API_KEY`. Bridge if only the former is set.
  defp bridge_gemini_to_google_api_key do
    case {System.get_env("GOOGLE_API_KEY"), System.get_env("GEMINI_API_KEY")} do
      {google, _} when google not in [nil, ""] -> :ok
      {_, gemini} when gemini not in [nil, ""] -> System.put_env("GOOGLE_API_KEY", gemini)
      _ -> :ok
    end
  end
end
