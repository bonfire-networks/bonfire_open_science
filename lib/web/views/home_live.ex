defmodule Bonfire.OpenScience.Web.HomeLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  declare_extension(
    "ExtensionTemplate",
    icon: "bi:app",
    default_nav: [
      Bonfire.OpenScience.Web.HomeLive,
      Bonfire.OpenScience.Web.AboutLive
    ]
  )

  declare_nav_link(l("Home"), page: "home", icon: "ri:home-line", emoji: "🧩")

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       page: "extension_template",
       page_title: "ExtensionTemplate"
     )}
  end

  def do_handle_event(
        "custom_event",
        _attrs,
        socket
      ) do
    # handle the event here
    {:noreply, socket}
  end

  def handle_params(params, uri, socket),
    do:
      Bonfire.UI.Common.LiveHandlers.handle_params(
        params,
        uri,
        socket,
        __MODULE__
      )

  def handle_info(info, socket),
    do: Bonfire.UI.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

  def handle_event(
        action,
        attrs,
        socket
      ),
      do:
        Bonfire.UI.Common.LiveHandlers.handle_event(
          action,
          attrs,
          socket,
          __MODULE__,
          &do_handle_event/3
        )
end
