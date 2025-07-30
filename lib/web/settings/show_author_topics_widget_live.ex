defmodule Bonfire.OpenScience.ShowAuthorTopicsWidgetLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop scope, :any, default: nil

  declare_settings_component("Author Topics Widget",
    icon: "fluent:brain-circuit-20-filled",
    description: "Display research topics associated with your publications from OpenAlex"
  )
end
