defmodule Bonfire.OpenScience do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  alias Bonfire.Common.Config
  alias Bonfire.Common.Utils
  use Bonfire.Common.E
  import Untangle

  def repo, do: Config.repo()

  def user_aliases(user) do
    Utils.maybe_apply(
      Bonfire.Social.Graph.Aliases,
      :list_aliases,
      [user],
      fallback_return: []
    )
    |> e(:edges, [])
  end
end
