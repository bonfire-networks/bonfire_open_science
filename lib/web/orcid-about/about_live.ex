defmodule Bonfire.OpenScience.Orcid.AboutLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop class, :any, default: nil

  prop user, :any, default: nil
  prop aliases, :any, default: []

  # def render(assigns) do
  #   user = assigns[:user]
  #   # debug(assigns)
  #   # should be loading this only once per persistent session, or when we open the composer
  #   assigns
  #   |> assign(
  #     :aliases,
  #     if(user,
  #       do:
  #         Utils.maybe_apply(
  #           Bonfire.Social.Graph.Aliases,
  #           :list_aliases,
  #           [user]
  #         )
  #         |> debug("list_aliases")
  #         |> e(:edges, []),
  #       else: []
  #     )
  #   )
  #   |> render_sface()
  # end
end
