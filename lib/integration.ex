defmodule Bonfire.OpenScience do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  alias Bonfire.Common.Config
  alias Bonfire.Common.Utils
  import Untangle

  def repo, do: Config.repo()
end
