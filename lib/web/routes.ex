defmodule Bonfire.OpenScience.Web.Routes do
  use Bonfire.Common.Localise
  import Bonfire.Common.Modularity.DeclareHelpers
  import Bonfire.UI.Common.Modularity.DeclareHelpers

  @behaviour Bonfire.UI.Common.RoutesModule

  declare_extension("Open Science",
    icon: "mingcute:microscope-fill",
    emoji: "🔬",
    description: l("The next generation of digital spaces for open science."),
    default_nav: [
      __MODULE__
    ]
  )

  declare_nav_link(l("Publications"),
    page: "research",
    # served by this route in `Bonfire.UI.Social`: `live("/feed/:tab/:object_types", FeedsLive, as: :feed)`)
    href: "/feed/research",
    icon: "carbon:document"
  )

  defmacro __using__(_) do
    quote do
      # pages anyone can view
      scope "/open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        live("/", HomeLive)
        live("/about", AboutLive)
      end

      # pages guests can view (including ORCID link for co-authors)
      scope "/open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        live("/orcid_link/:post_id", OrcidLinkLive)
      end

      # pages only guests can view
      scope "/open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        pipe_through(:guest_only)
      end

      # pages you need an account to view
      scope "/open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        pipe_through(:account_required)
      end

      # pages you need to view as a user
      scope "/open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        pipe_through(:user_required)
      end

      # pages only admins can view
      scope "/open_science/admin", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        pipe_through(:admin_required)
      end
    end
  end
end
