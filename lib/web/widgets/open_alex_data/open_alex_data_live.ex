defmodule Bonfire.OpenScience.OpenAlex.DataLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.OpenScience
  alias Bonfire.OpenScience.APIs

  prop user, :map, required: true
  prop open_alex_data, :map, default: nil

  def update(assigns, socket) do
    user = assigns[:user]
    aliases = OpenScience.user_aliases(user)
    orcid_id = APIs.find_orcid_id(aliases)

    if is_nil(orcid_id) do
      {:ok, assign(socket, :open_alex_data, nil)}
    else
      open_alex_data =
        Cache.maybe_apply_cached({APIs, :open_alex_fetch_topics}, [orcid_id])
        |> debug("OpenAlex")

      {:ok, assign(socket, :open_alex_data, open_alex_data)}
    end
  end

  def handle_event("show_all_topics", _params, socket) do
    {:noreply, socket}
  end
end
