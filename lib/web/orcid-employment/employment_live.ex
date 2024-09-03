defmodule Bonfire.OpenScience.Orcid.EmploymentLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop employments, :map, required: true
end
