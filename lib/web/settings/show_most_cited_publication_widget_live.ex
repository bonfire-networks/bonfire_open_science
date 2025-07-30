defmodule Bonfire.OpenScience.ShowMostCitedPublicationWidgetLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop scope, :any, default: nil

  declare_settings_component("Most Cited Publication Widget",
    icon: "fluent:trophy-20-filled",
    description: "Display your most cited work from OpenAlex"
  )
end
