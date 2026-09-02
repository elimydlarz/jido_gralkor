defmodule Gralkor.Artefact.ReturnHandler do
  @moduledoc "Consumer callback contract for delivering a Reflection artefact."

  @callback return(String.t(), String.t(), Gralkor.Artefact.t()) ::
              :ok | {:error, term()}
end
