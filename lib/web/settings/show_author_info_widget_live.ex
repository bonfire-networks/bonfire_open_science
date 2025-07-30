defmodule Bonfire.OpenScience.ShowAuthorInfoWidgetLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop scope, :any, default: nil

  declare_settings_component("Author Info Widget",
    icon: "fluent:person-info-20-filled",
    description:
      "Display author statistics like works count, citations, and h-index from OpenAlex"
  )
end
