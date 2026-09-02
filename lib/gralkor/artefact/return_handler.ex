defmodule Gralkor.Artefact.ReturnHandler do
  @moduledoc "Receives an artefact returned to the consuming application."

  @callback return(String.t(), String.t(), Gralkor.Artefact.t()) ::
              :ok | {:error, term()}
end
