defmodule Bonfire.OpenScience.Web.OrcidLinkLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  alias Bonfire.OpenScience.DOI
  alias Bonfire.OpenScience.ORCID
  alias Bonfire.OpenScience.Zenodo
  alias Bonfire.OpenScience.Zenodo.MetadataHelpers
  alias Bonfire.Social.Objects
  alias Req

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       page_title: l("Add ORCID to Publication"),
       page: "orcid_link",
       back: true,
       nav_items: Bonfire.Common.ExtensionModule.default_nav(),
       activity: nil,
       object: nil,
       user_id: nil,
       name: nil,
       loading: true,
       error: nil,
       valid: nil
     )}
  end

  def handle_params(%{"post_id" => post_id, "user_id" => user_id} = params, _url, socket) do
    debug(post_id, "Loading post for ORCID link page")
    current_user_id = current_user_id(socket)

    socket =
      socket
      |> assign(
        object_id: post_id,
        user_id: user_id,
        name: params["name"],
        loading: true
      )

    with %Phoenix.LiveView.Socket{} = socket <-
           Bonfire.Social.Objects.LiveHandler.load_object_assigns(socket) do
      # Use DOI from params directly - no need to extract from object
      {:noreply,
       socket
       |> assign(
         loading: false,
         valid: !current_user_id || current_user_id == user_id
       )}
    else
      {:error, e} ->
        {:noreply,
         socket
         |> assign_error(
           l(
             "The publication you're looking for doesn't exist or you don't have permission to view it."
           )
         )
         |> assign(loading: false, valid: false)}

      other ->
        error(other, "Failed to load post for ORCID link")

        {:noreply,
         socket
         |> assign(loading: false, valid: false)
         |> assign_error(l("There was an error loading the publication."))}
    end
  end

  def handle_event("submit_orcid", %{"orcid_id" => orcid_id} = params, socket) do
    # NOTE: this should also work for guests, when invoked without LiveView via the live handler fallback
    current_user = current_user(socket)

    case ORCID.validate(orcid_id) do
      {:ok, validated_orcid} ->
        object =
          e(assigns(socket), :object, nil) ||
            (params["object_id"] &&
               Bonfire.Social.Objects.read(params["object_id"],
                 current_user: current_user,
                 preload: [:with_media, :with_creator]
               )
               |> from_ok())

        user_id = params["user_id"] || id(current_user)

        case update_doi_metadata_with_orcid(
               socket,
               object,
               user_id,
               params["name"],
               validated_orcid
             ) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign_flash(
               :info,
               l("ORCID iD %{orcid} has been added to the publication metadata successfully!",
                 orcid: validated_orcid
               )
             )
             |> assign_generic(submitted_orcid: validated_orcid)}

          {:error, reason} ->
            error(reason, "Failed to update DOI metadata with ORCID")

            {:noreply,
             socket
             |> assign_error(
               l("Failed to update publication metadata with your ORCID.") <>
                 " " <>
                 if(is_binary(reason),
                   do: reason,
                   else: l("Please try again or contact support.")
                 )
             )}
        end

      {:error, _error} ->
        {:noreply,
         socket
         |> assign_error(l("Invalid ORCID format. Please use the format: XXXX-XXXX-XXXX-XXXX"))}
    end
  end

  # Helper functions

  # Updates the DOI metadata in Zenodo with the user's ORCID
  defp update_doi_metadata_with_orcid(socket, object, user_id, name, orcid_id) do
    current_user = current_user(socket)

    debug({current_user, orcid_id, user_id}, "Starting DOI metadata update with ORCID")

    with {:ok, _media, deposit_info} <-
           Zenodo.get_thread_zenodo_media(
             e(object, :activity, :media, nil) || e(object, :media, nil) ||
               e(assigns(socket), :activity, :media, nil)
           ),
         {:ok, access_token, api_type} <- MetadataHelpers.find_original_publisher_token(object),
         _ = debug(deposit_info, "Got deposit info for debugging"),
         {:ok, working_deposit_info, working_deposit_id} <-
           ensure_editable_deposit(
             deposit_info,
             e(deposit_info, "id", nil),
             access_token,
             api_type
           ),
         {:ok, updated_creators} <-
           creators_with_updated_orcid(working_deposit_info, user_id, name, orcid_id),
         {:ok, result} <-
           Zenodo.handle_zenodo_edit_workflow(
             working_deposit_info,
             working_deposit_id,
             updated_creators,
             working_deposit_info["metadata"],
             access_token,
             api_type
           ) do
      debug(result, "Successfully updated DOI metadata")
      {:ok, result}
    end
  end

  # Update the creators list with the new ORCID for the given user_id
  defp creators_with_updated_orcid(deposit_info, user_id, name, orcid_id) do
    current_creators = e(deposit_info, "metadata", "creators", [])

    debug(
      {user_id, length(current_creators)},
      "Looking for user_id in creators list"
    )

    # Track if any creator was updated while mapping
    {updated_creators, updated?} =
      Enum.map_reduce(current_creators, false, fn creator, acc_updated? ->
        if creator["id"] == user_id or creator["name"] == name do
          {Map.put(creator, "orcid", orcid_id), true}
        else
          {creator, acc_updated?}
        end
      end)

    if updated? do
      debug("Successfully updated creator(s) with ORCID")
      {:ok, updated_creators}
    else
      error(current_creators, "Could not find the specified user in the creators list")
    end
  end

  # Ensures we can update the deposit - just pass through as the update logic handles published/unpublished
  def ensure_editable_deposit(deposit_info, deposit_id, _access_token, _api_type) do
    debug({deposit_id}, "Deposit info received, will handle in update logic")
    {:ok, deposit_info, deposit_id}
  end
end
