defmodule JidoGralkor.BlockingFlushClient do
  @moduledoc false

  @spec install(pid()) :: :ok
  def install(owner) when is_pid(owner) do
    previous_client = Application.fetch_env!(:jido_gralkor, :client)
    Application.put_env(:jido_gralkor, :client, __MODULE__)
    Application.put_env(:jido_gralkor, __MODULE__, owner)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:jido_gralkor, :client, previous_client)
      Application.delete_env(:jido_gralkor, __MODULE__)
    end)

    :ok
  end

  @spec release(pid(), :ok | {:error, term()}) :: :ok
  def release(flusher, response) when is_pid(flusher) do
    send(flusher, {:release_flush, response})
    :ok
  end

  @spec flush_and_await(String.t(), pos_integer()) :: :ok | {:error, term()}
  def flush_and_await(session_id, timeout_ms) do
    owner = Application.fetch_env!(:jido_gralkor, __MODULE__)
    send(owner, {:flush_started, self(), session_id, timeout_ms})

    receive do
      {:release_flush, response} -> response
    end
  end
end
