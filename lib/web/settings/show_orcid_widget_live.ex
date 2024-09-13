defmodule Bonfire.OpenScience.ShowOrcidWidgetLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop scope, :any, default: nil

  declare_settings_component("ORCID Info", icon: "fluent:people-team-16-filled")
end
