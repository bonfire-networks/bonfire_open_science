defmodule Bonfire.OpenScience.OpenAlex.AffiliationsLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.OpenScience.Publications

  prop user, :map, required: true
  prop aliases, :list, default: []
  prop open_alex_data, :map, default: nil
  prop affiliations, :list, default: []

  def update(assigns, socket) do
    user = assigns[:user]

    case Publications.get_author_info(user) do
      {:ok, open_alex_data} ->
        debug(open_alex_data, "OpenAlex data for affiliations")
        
        {:ok,
         assign(socket,
           open_alex_data: open_alex_data,
           affiliations: e(open_alex_data, "affiliations", [])
         )}
      
      {:error, reason} ->
        debug(reason, "Could not fetch author info for affiliations")
        {:ok, assign(socket, open_alex_data: nil, affiliations: [])}
    end
  end

  def filter_unique_affiliations(affiliations) when is_list(affiliations) do
    affiliations
    |> Enum.uniq_by(fn affiliation -> e(affiliation, "institution", "id", nil) end)
    |> Enum.filter(fn affiliation -> e(affiliation, "institution", "display_name", nil) end)
  end

  def filter_unique_affiliations(_), do: []
end
