defmodule Bonfire.OpenScience.ShowAffiliationsWidgetLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop scope, :any, default: nil

  declare_settings_component("Affiliations Widget",
    icon: "fluent:building-20-filled",
    description: "Display your institutional affiliations from ORCID on your profile page"
  )
end
