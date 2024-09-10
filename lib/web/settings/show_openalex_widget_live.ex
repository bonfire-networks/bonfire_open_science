defmodule Bonfire.OpenScience.ShowOpenAlexWidgetLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop scope, :any, default: nil

  declare_settings_component("OpenAlex Integration", icon: "fluent:people-team-16-filled")
end
