defmodule Nix.Cache.UploadError do
  @moduledoc """
  Upload failure from a cache backend.

  Carries the full command output so the presentation layer can decide
  how much to show.
  """

  use TypedStruct

  typedstruct do
    field :backend, String.t(), enforce: true
    field :exit_code, integer(), enforce: true
    field :output, String.t(), enforce: true
  end
end
