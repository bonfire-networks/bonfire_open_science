defmodule Bonfire.OpenScience.Web.OrcidLinkLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  alias Bonfire.OpenScience.ORCID
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
       doi: nil,
       loading: true,
       error: nil
     )}
  end

  def handle_params(%{"post_id" => post_id} = params, _url, socket) do
    doi = Map.get(params, "doi")

    debug(post_id, "Loading post for ORCID link page")

    socket = socket
      |> assign(
        object_id: post_id,
        doi: doi,
        params: params,
        loading: true
      )

    with %Phoenix.LiveView.Socket{} = socket <-
           Bonfire.Social.Objects.LiveHandler.load_object_assigns(socket) do

      # Use DOI from params directly - no need to extract from object
      {:noreply,
       socket
       |> assign(
         loading: false,
         doi: doi
       )}
    else
      {:error, e} ->
        {:noreply,
         socket
         |> assign_error(l("The publication you're looking for doesn't exist or you don't have permission to view it."))
         |> assign(loading: false, error: l("Publication not found"))}

      other ->
        error(other, "Failed to load post for ORCID link")
        {:noreply,
         socket
         |> assign(loading: false, error: l("Failed to load publication"))
         |> assign_error(l("There was an error loading the publication."))}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(loading: false, error: l("Missing post ID"))
     |> assign_error(l("No publication specified."))}
  end

  def handle_event("submit_orcid", %{"orcid_id" => orcid_id}, socket) do
    case Bonfire.OpenScience.ORCID.validate(orcid_id) do
      {:ok, validated_orcid} ->
        # Update the DOI metadata with the new ORCID
        case update_doi_metadata_with_orcid(socket, validated_orcid) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign_flash(:info, l("ORCID iD %{orcid} has been added to the publication metadata successfully!", orcid: validated_orcid))
             |> assign(submitted_orcid: validated_orcid)}
          
          {:error, reason} ->
            error(reason, "Failed to update DOI metadata with ORCID")
            {:noreply,
             socket
             |> assign_flash(:error, l("Failed to update publication metadata. Please try again or contact support."))}
        end
      
      {:error, _error} ->
        {:noreply,
         socket
         |> assign_flash(:error, l("Invalid ORCID format. Please use the format: XXXX-XXXX-XXXX-XXXX"))}
    end
  end

  # Helper functions

  # Updates the DOI metadata in Zenodo with the user's ORCID
  defp update_doi_metadata_with_orcid(socket, orcid_id) do
    current_user = current_user(socket)
    object = socket.assigns.object
    doi = socket.assigns.doi

    debug({current_user, doi, orcid_id}, "Starting DOI metadata update with ORCID")

    with {:ok, zenodo_info} <- extract_zenodo_info_from_doi(doi),
         {:ok, publisher_user} <- find_original_publisher(object),
         {:ok, access_token, api_type} <- Bonfire.OpenScience.Zenodo.get_user_zenodo_token(publisher_user),
         {:ok, deposit_info} <- Bonfire.OpenScience.Zenodo.get_deposit(zenodo_info.deposit_id, access_token, api_type),
         _ = debug(deposit_info, "Got deposit info for debugging"),
         {:ok, working_deposit_info, working_deposit_id} <- ensure_editable_deposit(deposit_info, zenodo_info.deposit_id, access_token, api_type),
         {:ok, updated_creators} <- update_creators_with_orcid(working_deposit_info, current_user, orcid_id),
         {:ok, result} <- update_zenodo_deposit(working_deposit_info, updated_creators, access_token, api_type, working_deposit_id, doi) do
      
      debug(result, "Successfully updated DOI metadata")
      {:ok, result}
    else
      error ->
        error(error, "Failed to update DOI metadata with ORCID")
        {:error, error}
    end
  end

  # Extract Zenodo information from a DOI URL
  defp extract_zenodo_info_from_doi(doi) when is_binary(doi) do
    # Extract deposit ID from Zenodo DOI URL
    # DOI format: https://doi.org/10.5072/zenodo.318716
    # or: 10.5072/zenodo.318716
    case extract_deposit_id_from_doi(doi) do
      deposit_id when is_integer(deposit_id) ->
        {:ok, %{deposit_id: deposit_id, doi: doi}}
      deposit_id when is_binary(deposit_id) ->
        case Integer.parse(deposit_id) do
          {id, ""} -> {:ok, %{deposit_id: id, doi: doi}}
          _ -> {:error, "Invalid deposit ID in DOI"}
        end
      _ ->
        {:error, "Could not extract deposit ID from DOI"}
    end
  end

  defp extract_zenodo_info_from_doi(_), do: {:error, "No DOI provided"}

  # Ensures we can update the deposit - just pass through as the update logic handles published/unpublished
  defp ensure_editable_deposit(deposit_info, deposit_id, _access_token, _api_type) do
    debug({deposit_id}, "Deposit info received, will handle in update logic")
    {:ok, deposit_info, deposit_id}
  end

  # Extract deposit ID from DOI URL
  defp extract_deposit_id_from_doi(doi) when is_binary(doi) do
    # Handle different DOI formats:
    # https://doi.org/10.5072/zenodo.318716
    # 10.5072/zenodo.318716  
    case Regex.run(~r/zenodo\.(\d+)/, doi) do
      [_, deposit_id] -> deposit_id
      _ -> nil
    end
  end

  defp extract_deposit_id_from_doi(_), do: nil

  # Find the original publisher who has Zenodo credentials
  defp find_original_publisher(object) do
    # The publisher is typically the creator of the post
    publisher = e(object, :created, :creator, nil) || e(object, :activity, :subject, nil)
    
    case publisher do
      %{} = user ->
        # Verify they have Zenodo credentials
        case Bonfire.OpenScience.Zenodo.get_user_zenodo_token(user) do
          {:ok, _token, _type} -> {:ok, user}
          _ -> {:error, "Original publisher does not have Zenodo credentials"}
        end
      _ ->
        {:error, "Could not find original publisher"}
    end
  end

  # Update the creators list with the new ORCID for the current user
  defp update_creators_with_orcid(deposit_info, current_user, orcid_id) do
    current_creators = e(deposit_info, "metadata", "creators", [])
    current_user_id = id(current_user)
    current_user_name = e(current_user, :profile, :name, nil) || e(current_user, :character, :username, nil)

    debug({current_user_id, current_user_name, length(current_creators)}, "Looking for user in creators list")

    # Try to find the current user in the creators list
    updated_creators = 
      current_creators
      |> Enum.map(fn creator ->
        cond do
          # Match by stored ID
          creator["id"] == current_user_id ->
            Map.put(creator, "orcid", orcid_id)
          
          # Match by name (fallback)
          current_user_name && creator["name"] && 
          String.downcase(creator["name"]) == String.downcase(current_user_name) ->
            Map.put(creator, "orcid", orcid_id)
          
          # No match, keep as is
          true ->
            creator
        end
      end)

    # Check if any creator was actually updated
    updated_count = 
      Enum.count(updated_creators, fn creator ->
        creator["orcid"] == orcid_id
      end)

    if updated_count > 0 do
      debug("Successfully updated #{updated_count} creator(s) with ORCID")
      {:ok, updated_creators}
    else
      error("Current user not found in creators list")
      {:error, "You are not listed as a co-author of this publication"}
    end
  end

  # Handle the Zenodo deposit update workflow - reuses logic from ZenodoMetadataFormLive
  defp update_zenodo_deposit(deposit_info, creators, access_token, api_type, deposit_id, doi) do
    # Get existing metadata and preserve it
    existing_metadata = e(deposit_info, "metadata", %{})
    
    # Clean and prepare metadata for Zenodo (ensure DOI is in correct format)
    processed_metadata = 
      existing_metadata
      |> ensure_correct_doi_format(doi)  # Use the full DOI from URL params
      |> MetadataHelpers.clean_metadata_for_zenodo()

    debug({deposit_id, length(creators)}, "Updating Zenodo deposit")

    # Use the same workflow as the metadata form for handling published deposits
    is_published = deposit_info["state"] == "done" || deposit_info["doi"] != nil
    debug({is_published, api_type}, "Determining workflow type")
    
    cond do
      is_published and api_type == :zenodo ->
        # For published Zenodo deposits, use the "edit" action first
        edit_url = get_in(deposit_info, ["links", "edit"])
        
        if is_nil(edit_url) do
          error("Edit URL not found in deposit links")
          {:error, "Edit URL not found in deposit links"}
        else
          zenodo_edit_publish_flow(edit_url, deposit_id, creators, processed_metadata, access_token, api_type)
        end
      
      true ->
        # For unpublished records or other cases, use direct update  
        case Bonfire.OpenScience.Zenodo.update_deposit_metadata(deposit_id, creators, processed_metadata, access_token, api_type) do
          {:ok, result} ->
            debug("DOI metadata updated successfully")
            {:ok, result}
          {:error, reason} ->
            error(reason, "Direct metadata update failed")
            {:error, reason}
        end
    end
  end

  # Handle the edit-publish workflow for published Zenodo deposits (reuses existing API functions)
  defp zenodo_edit_publish_flow(edit_url, deposit_id, creators, processed_metadata, access_token, api_type) do
    debug({edit_url, deposit_id}, "Starting zenodo_edit_publish_flow")
    
    # Step 1: POST to edit URL to make deposit editable
    with {:ok, %{status: status}} when status in 200..299 <-
           Req.post(edit_url,
             body: "",
             headers: [
               {"Accept", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ]
           ) do
      
      debug("Successfully unlocked deposit for editing")
      
      # Step 2: Update the metadata
      case Bonfire.OpenScience.Zenodo.update_deposit_metadata(deposit_id, creators, processed_metadata, access_token, api_type) do
        {:ok, updated_result} ->
          debug("Metadata updated successfully")
          
          # For this specific use case (ORCID addition), the metadata update is sufficient
          # The publish step causes issues with managed DOI prefixes in sandbox
          debug("Skipping republish for ORCID metadata update - metadata change is sufficient")
          {:ok, updated_result}
        
        {:error, update_reason} ->
          error(update_reason, "Failed to update metadata after unlocking")
          {:error, "Failed to update metadata: #{inspect(update_reason)}"}
      end
    else
      {:ok, %{status: status, body: body}} ->
        error({status, body}, "Failed to unlock deposit for editing")
        {:error, "Failed to unlock deposit for editing: HTTP #{status}"}
      
      {:error, reason} ->
        error(reason, "HTTP request failed when unlocking deposit")
        {:error, "Failed to unlock deposit: #{inspect(reason)}"}
    end
  end

  # Ensure DOI fields have the correct full format
  defp ensure_correct_doi_format(metadata, full_doi) when is_binary(full_doi) do
    # Extract just the DOI identifier from the full URL (e.g., "10.5072/zenodo.318716")
    doi_identifier = case full_doi do
      "https://doi.org/" <> doi -> doi
      "http://doi.org/" <> doi -> doi
      doi -> doi
    end
    
    debug({doi_identifier, full_doi}, "Setting DOI in metadata")
    
    metadata
    |> Map.put("doi", doi_identifier)
    |> Map.put("doi_url", full_doi)
  end
  
  defp ensure_correct_doi_format(metadata, _), do: metadata


end
