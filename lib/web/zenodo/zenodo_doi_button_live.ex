defmodule Bonfire.OpenScience.ZenodoDoiButtonLive do
  use Bonfire.UI.Common.Web, :stateless_component
  import Bonfire.Common

  prop post, :map, required: true
  prop class, :css_class, default: "btn btn-sm btn-ghost"
  prop parent_id, :string, required: true
  prop participants, :any, default: nil
end
