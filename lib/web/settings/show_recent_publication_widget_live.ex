defmodule Bonfire.OpenScience.ShowRecentPublicationWidgetLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop scope, :any, default: nil

  declare_settings_component("Recent Publication Widget",
    icon: "fluent:document-recent-20-filled",
    description: "Display your most recently published work from OpenAlex"
  )
end
