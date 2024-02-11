defmodule Bonfire.OpenScience.Web.AboutLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  declare_nav_link(l("About"),
    page: "About",
    href: "/bonfire_open_science/about",
    icon: "typcn:info-large"
  )

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       page: "About",
       page_title: "About the extension",
       nav_items: Bonfire.Common.ExtensionModule.default_nav(:bonfire_open_science)
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
