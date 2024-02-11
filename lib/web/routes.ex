defmodule Bonfire.OpenScience.Web.Routes do
  def declare_routes, do: nil

  defmacro __using__(_) do
    quote do
      # pages anyone can view
      scope "/bonfire_open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)

        live("/", HomeLive)
        live("/about", AboutLive)
      end

      # pages only guests can view
      scope "/bonfire_open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        pipe_through(:guest_only)
      end

      # pages you need an account to view
      scope "/bonfire_open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        pipe_through(:account_required)
      end

      # pages you need to view as a user
      scope "/bonfire_open_science/", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        pipe_through(:user_required)
      end

      # pages only admins can view
      scope "/bonfire_open_science/admin", Bonfire.OpenScience.Web do
        pipe_through(:browser)
        pipe_through(:admin_required)
      end
    end
  end
end
