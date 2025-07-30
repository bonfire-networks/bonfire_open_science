defmodule Bonfire.OpenScience.ShowPublicationTypesWidgetLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop scope, :any, default: nil

  declare_settings_component("Publication Types Widget",
    icon: "fluent:document-data-20-filled",
    description:
      "Display a breakdown of your publications by type (articles, books, etc.) from OpenAlex"
  )
end
