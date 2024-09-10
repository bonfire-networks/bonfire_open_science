defmodule Bonfire.OpenScience.OpenAlex.DataLive do
  use Bonfire.UI.Common.Web, :stateful_component

  prop user, :map, required: true
  prop open_alex_data, :map, default: nil

  def update(assigns, socket) do
    user = assigns[:user]
    aliases = fetch_aliases(user)
    orcid_id = find_orcid_id(aliases)

    if is_nil(orcid_id) do
      socket = assign(socket, :open_alex_data, nil)
      {:ok, socket}
    else
      orcid = String.replace(orcid_id, "https://orcid.org/", "")
      open_alex_data = fetch_topics(orcid)
      socket = assign(socket, :open_alex_data, open_alex_data)
      {:ok, socket}
    end
  end

  def handle_event("show_all_topics", _params, socket) do
    {:noreply, socket}
  end

  defp fetch_aliases(user) do
    Utils.maybe_apply(
      Bonfire.Social.Graph.Aliases,
      :list_aliases,
      [user],
      fallback_return: []
    )
    |> e(:edges, [])
  end

  def find_orcid_id(aliases) do
    Enum.find_value(aliases, fn alias ->
      if e(alias, :edge, :object, :media_type, "") == "orcid", do: e(alias, :edge, :object, :path, ""), else: nil
    end)
  end

  defp fetch_topics(orcid_id) do
    url = "https://api.openalex.org/authors/orcid:#{orcid_id}"
    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        data = Jason.decode!(body)
        data
      _ ->
        []
    end
  end

end
