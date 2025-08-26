defmodule Bonfire.OpenScience.Zenodo do
  @moduledoc """
  Zenodo API client for submitting metadata, uploading files, and creating DOIs.
  """

  use Bonfire.Common.Utils
  alias Bonfire.OpenScience
  alias Bonfire.OpenScience.Zenodo
  alias Bonfire.OpenScience.Zenodo.MetadataHelpers

  @base_url "https://zenodo.org/api"
  @sandbox_url "https://sandbox.zenodo.org/api"

  @doc """
  Creates a Zenodo deposit for a user using their stored Zenodo access token, uploads files, and publishes.

  ## Parameters
  - user: The user who owns the Zenodo credentials
  - metadata: Map containing deposit metadata
  - opts: Additional options (eg. auto_publish: true/false)

  ## Returns
  {:ok, deposit} on success, {:error, reason} on failure
  """
  def publish_deposit_for_user(user, creators, metadata, files, opts \\ []) do
    with {:ok, access_token, api_type} <- get_user_zenodo_token(user),
         {:ok, result} <-
           create_and_upload(creators, metadata, files, access_token, api_type, opts) do
      {:ok, result}
    end
  end

  @doc """
  Gets the Zenodo access token for a user from their stored media.

  ## Parameters
  - user: The user to get the token for

  ## Returns
  {:ok, access_token, api_type} on success, {:error, reason} on failure
  """
  def get_user_zenodo_token(user) do
    case OpenScience.user_alias_by_type(user, "zenodo") do
      nil ->
        if token = System.get_env("INVENIO_RDM_PERSONAL_TOKEN") do
          {:ok, token, :invenio}
        else
          {:error, :no_zenodo_credentials}
        end

      zenodo_media ->
        access_token = e(zenodo_media, :metadata, "zenodo", "access_token", nil)

        if access_token && access_token != "" do
          {:ok, access_token, :zenodo}
        else
          {:error, :invalid_zenodo_credentials}
        end
    end
  end

  def get_user_api_type(user) do
    with {:ok, _access_token, api_type} <- get_user_zenodo_token(user) do
      api_type
    else
      _e ->
        nil
    end
  end

  @doc """
  Complete deposition workflow for Zenodo: creates a deposit, uploads files, and publishes.

  ## Parameters
  - metadata: Map containing deposit metadata
  - files: List of file paths or {file_path, filename} tuples to upload
  - access_token: Zenodo API access token
  - opts: Additional options (eg. auto_publish: true/false)

  ## Returns
  {:ok, %{deposit: deposit, files: file_infos, published: published_record}} on success
  """
  def create_and_upload(creators, metadata, files, access_token, api_type \\ :zenodo, opts \\ []) do
    with {:ok, deposit} <- create_deposit(creators, metadata, access_token, api_type, opts),
         deposit_id = e(deposit, "id", nil),
         bucket_url = e(deposit, "links", "bucket", nil),
         {:ok, file_infos} <-
           upload_files(bucket_url || deposit_id, files, access_token, api_type, opts),
         result = %{deposit: deposit, files: file_infos} do
      # return the draft and/or published record
      {:ok, Map.put(result, :published, maybe_publish(deposit_id, access_token, api_type, opts))}

      # auto_publish = Keyword.get(opts, :auto_publish, true)

      # case maybe_publish(deposit_id, access_token, api_type, opts) do
      #   false when auto_publish ->
      #     # Auto-publish was requested but failed
      #     {:error, :publish_failed}

      #   published_result ->
      #     # Either published successfully or auto_publish was false
      #     {:ok, Map.put(result, :published, published_result)}
      # end
    end
  end

  def maybe_publish(deposit_id, access_token, api_type \\ :zenodo, opts \\ []) do
    if Keyword.get(opts, :auto_publish, true) do
      case publish_deposit(deposit_id, access_token, api_type, opts) do
        {:ok, published_record} ->
          published_record

        {:error, reason} ->
          error(reason, "Failed to publish deposit #{deposit_id}")
          false
      end
    else
      false
    end
  end

  @doc """
  Creates a new empty deposit on Zenodo with the given metadata.

  ## Parameters
  - metadata: Map containing deposit metadata (title, upload_type, description, creators, etc.)
  - access_token: Zenodo API access token
  - opts: Additional options

  ## Returns
  {:ok, deposit} on success, {:error, reason} on failure
  """
  def create_deposit(creators, metadata, access_token, api_type \\ :zenodo, opts \\ []) do
    url = build_url(:deposit, access_token, api_type, opts)
    debug(url, "Zenodo API URL")

    payload = format_payload_for_api(creators, metadata, api_type)

    debug(payload, "Zenodo API payload being sent")

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.post(url,
             json: payload,
             headers: [
               {"Accept", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ],
             # 60 seconds timeout for Zenodo API
             receive_timeout: 60_000
           ) do
      {:ok, body}
    else
      {:error, %Jason.EncodeError{} = e} ->
        error(e, "Failed to encode metadata as JSON")

      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo API error: #{status}")

      {:error, reason} ->
        error(reason, "HTTP request failed")
    end
  end

  @doc """
  Uploads a file to an existing Zenodo deposit using the new files API.

  ## Parameters
  - bucket_url: The bucket URL from the deposit's links
  - file_input: Local path to the file, or a stream, or {stream, filename} tuple
  - access_token: Zenodo API access token
  - filename: Name to give the file in Zenodo (optional, defaults to basename of file_path for paths)

  ## Returns
  {:ok, file_info} on success, {:error, reason} on failure
  """
  def upload_file(
        bucket_url_or_record_id,
        file_input,
        access_token,
        api_type \\ :zenodo,
        filename \\ nil,
        opts \\ []
      ) do
    with {:ok, {final_filename, file_data}} <- prepare_upload_data(file_input, filename) do
      case api_type do
        :zenodo ->
          upload_url =
            build_url(:upload_file, access_token, :zenodo, %{
              bucket_url: bucket_url_or_record_id,
              filename: final_filename
            })

          Req.put(upload_url,
            body: file_data,
            headers: [
              {"Authorization", "Bearer #{access_token}"},
              {"Content-Type", "application/octet-stream"}
            ]
          )
          |> case do
            {:ok, %{body: body, status: status}} when status in 200..299 ->
              {:ok, body}

            {:ok, %{status: status, body: body}} ->
              error(body, "File upload to Zenodo failed: #{status}")

            {:error, reason} ->
              error(reason, "File upload to Zenodo failed")
          end

        :invenio ->
          # Step 1: Initialize file
          record_id = bucket_url_or_record_id
          init_url = build_url(:upload_file_init, access_token, :invenio, %{id: record_id})

          with {:ok, %{status: 201}} <-
                 Req.post(init_url,
                   json: [%{key: final_filename}],
                   headers: [{"Authorization", "Bearer #{access_token}"}]
                 ),
               # Step 2: Upload content
               content_url =
                 build_url(:upload_file_content, access_token, :invenio, %{
                   id: record_id,
                   filename: final_filename
                 }),
               {:ok, %{status: 200}} <-
                 Req.put(content_url,
                   body: file_data,
                   headers: [
                     {"Authorization", "Bearer #{access_token}"},
                     {"Content-Type", "application/octet-stream"}
                   ]
                 ),
               # Step 3: Commit file
               commit_url =
                 build_url(:upload_file_commit, access_token, :invenio, %{
                   id: record_id,
                   filename: final_filename
                 }),
               {:ok, %{body: body, status: 200}} <-
                 Req.post(commit_url,
                   headers: [{"Authorization", "Bearer #{access_token}"}]
                 ) do
            {:ok, body}
          else
            {:error, :enoent} ->
              error(file_input, "File to be uploaded not found")
              {:error, :enoent}

            {:ok, %{status: status, body: body}} ->
              error(body, "File upload to Invenio failed: #{status}")

            {:error, reason} ->
              error(reason, "File upload to Invenio failed")
              {:error, reason}
          end
      end
    else
      {:error, :enoent} ->
        error(file_input, "File to be uploaded not found")
        {:error, :enoent}

      {:error, reason} ->
        error(reason, "File upload failed")
        {:error, reason}
    end
  end

  @doc """
  Publishes a Zenodo deposit, making it publicly available and assigning a DOI.

  ## Parameters
  - deposit_id: The ID of the deposit to publish
  - access_token: Zenodo API access token
  - opts: Additional options

  ## Returns
  {:ok, published_record} on success, {:error, reason} on failure
  """
  def publish_deposit(deposit_id, access_token, api_type, opts \\ []) do
    url = build_url(:publish, access_token, api_type, %{id: deposit_id})

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.post(url,
             body: "",
             headers: [
               {"Content-Type", "application/json"},
               {"Accept", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ]
           ) do
      {:ok, body}
    else
      {:ok, %{status: status, body: %{"message" => message, "errors" => errors} = body}} ->
        error(body, "Publish request failed: #{message} #{zenodo_error_to_message(errors)}")

      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo publish error: #{status}")

      {:error, reason} ->
        error(reason, "Publish request failed")
        {:error, reason}
    end
  end

  @doc """
  Retrieves information about an existing deposit.

  ## Parameters
  - deposit_id: The ID of the deposit to retrieve
  - access_token: Zenodo API access token
  - opts: Additional options

  ## Returns
  {:ok, deposit} on success, {:error, reason} on failure
  """
  def get_deposit(deposit_id, access_token, api_type \\ :zenodo, opts \\ []) do
    url = build_url(:deposit, access_token, api_type)

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.get("#{url}/#{deposit_id}",
             headers: [
               {"Accept", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ]
           ) do
      {:ok, body}
    else
      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo API error: #{status}")

      {:error, reason} ->
        error(reason, "HTTP request failed")
        {:error, reason}
    end
  end

  @doc """
  Updates metadata for an existing unpublished deposit.

  ## Parameters
  - deposit_id: The ID of the deposit to update
  - creators: List of creator maps
  - metadata: Updated metadata map
  - access_token: Zenodo API access token
  - api_type: :zenodo or :invenio
  - opts: Additional options

  ## Returns
  {:ok, updated_deposit} on success, {:error, reason} on failure
  """
  def update_deposit_metadata(
        deposit_id,
        creators,
        metadata,
        access_token,
        api_type \\ :zenodo,
        opts \\ []
      ) do
    url = build_url(:update_deposit, access_token, api_type, %{id: deposit_id})

    payload = format_payload_for_api(creators, metadata, api_type)

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.put(url,
             json: payload,
             headers: [
               {"Accept", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ],
             receive_timeout: 60_000
           ) do
      {:ok, body}
    else
      {:error, %Jason.EncodeError{} = e} ->
        error(e, "Failed to encode metadata as JSON")

      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo API error: #{status}")

      {:error, reason} ->
        error(reason, "HTTP request failed")
        {:error, reason}
    end
  end

  @doc """
  Creates a new version of a published deposit.

  ## Parameters
  - deposit_id: The ID of the published deposit to create a new version from
  - access_token: Zenodo API access token
  - api_type: :zenodo or :invenio
  - opts: Additional options

  ## Returns
  {:ok, new_deposit} on success, {:error, reason} on failure
  """
  def create_new_version(deposit_id, access_token, api_type \\ :zenodo, opts \\ []) do
    url = build_url(:new_version, access_token, api_type, %{id: deposit_id})

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.post(url,
             body: "",
             headers: [
               {"Accept", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ],
             receive_timeout: 60_000
           ) do
      {:ok, body}
    else
      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo API error: #{status}")

      {:error, reason} ->
        error(reason, "HTTP request failed")
        {:error, reason}
    end
  end

  # Private helper functions

  @doc false
  defp format_payload_for_api(creators, metadata, api_type) do
    if api_type == :invenio do
      # InvenioRDM format
      %{
        "metadata" =>
          metadata
          |> MetadataHelpers.clean_metadata_for_zenodo()
          |> Map.put_new("resource_type", %{"id" => "dataset"})
          |> Map.put_new("publisher", get_publisher_name())
          |> Map.put("creators", format_creators_for_invenio(creators))
      }
    else
      # Zenodo format
      %{"metadata" => metadata |> Map.put("creators", creators)}
    end
  end

  @doc false
  defp format_creators_for_invenio(creators) do
    creators
    |> Enum.map(fn creator ->
      person_or_org = %{
        "given_name" => creator["given_name"],
        "family_name" => creator["family_name"] || creator["name"],
        "type" => "personal",
        "name" => creator["name"] || "#{creator["given_name"]} #{creator["family_name"]}"
      }

      person_or_org =
        case creator["orcid"] do
          orcid when is_binary(orcid) and orcid != "" ->
            Map.put(person_or_org, "identifiers", [
              %{"identifier" => orcid, "scheme" => "orcid"}
            ])

          _ ->
            person_or_org
        end

      affiliations = format_affiliations(creator["affiliations"] || creator["affiliation"])

      if affiliations != [] do
        %{"person_or_org" => person_or_org, "affiliations" => affiliations}
      else
        %{"person_or_org" => person_or_org}
      end
    end)
  end

  @doc false
  defp format_affiliations(nil), do: []
  defp format_affiliations([]), do: []

  defp format_affiliations(affs) when is_list(affs) do
    affs
    |> Enum.map(fn
      a when is_map(a) -> a["name"]
      a -> a
    end)
    |> Enum.filter(&(&1 && &1 != ""))
    |> Enum.map(&%{"name" => &1})
  end

  defp format_affiliations(%{"name" => name} = aff) when is_binary(name) and name != "", do: [aff]
  defp format_affiliations(aff) when is_binary(aff) and aff != "", do: [%{"name" => aff}]
  defp format_affiliations(_), do: []

  @doc false
  defp get_publisher_name do
    Bonfire.Common.Config.get([:bonfire_open_science, :publisher_name], "Open Science Network")
  end

  defp build_url(path_type, access_token, api_type, params \\ %{}) do
    case {api_type, path_type} do
      {:zenodo, :deposit} ->
        "#{zenodo_base_url()}/deposit/depositions"

      {:zenodo, :upload_file} ->
        "#{params[:bucket_url]}/#{params[:filename]}"

      {:zenodo, :publish} ->
        "#{zenodo_base_url()}/deposit/depositions/#{params[:id]}/actions/publish"

      {:zenodo, :update_deposit} ->
        "#{zenodo_base_url()}/deposit/depositions/#{params[:id]}"

      {:zenodo, :new_version} ->
        "#{zenodo_base_url()}/deposit/depositions/#{params[:id]}/actions/newversion"

      {:invenio, :deposit} ->
        "#{invenio_base_url()}/records"

      {:invenio, :upload_file_init} ->
        "#{invenio_base_url()}/records/#{params[:id]}/draft/files"

      {:invenio, :upload_file_content} ->
        "#{invenio_base_url()}/records/#{params[:id]}/draft/files/#{params[:filename]}/content"

      {:invenio, :upload_file_commit} ->
        "#{invenio_base_url()}/records/#{params[:id]}/draft/files/#{params[:filename]}/commit"

      {:invenio, :publish} ->
        "#{invenio_base_url()}/records/#{params[:id]}/draft/actions/publish"

      {:invenio, :update_deposit} ->
        "#{invenio_base_url()}/records/#{params[:id]}/draft"

      {:invenio, :new_version} ->
        "#{invenio_base_url()}/records/#{params[:id]}/versions"

      _ ->
        raise ArgumentError,
              "Unknown API or path type: #{inspect(api_type)}, #{inspect(path_type)}"
    end
  end

  def zenodo_base_url do
    if System.get_env("ZENODO_ENV") == "sandbox", do: @sandbox_url, else: @base_url
  end

  def invenio_base_url do
    System.get_env("INVENIO_RDM_API_URL")
  end

  defp upload_files(bucket_url_or_record_id, files, access_token, api_type, opts \\ []) do
    files
    |> normalize_file_list()
    |> Enum.reduce_while({:ok, []}, fn {filename, file_input}, {:ok, acc} ->
      case upload_file(
             bucket_url_or_record_id,
             file_input,
             access_token,
             api_type,
             filename,
             opts
           ) do
        {:ok, file_info} -> {:cont, {:ok, [file_info | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, file_infos} -> {:ok, Enum.reverse(file_infos)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_file_list(files) do
    Enum.map(files || [], fn
      nil -> nil
      {filename, nil} -> nil
      {filename, file_input} -> {filename, file_input}
      file_input -> {nil, file_input}
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Checks if a thread/post has been archived to Zenodo by looking for attached media with Zenodo metadata.

  ## Parameters
  - post: The post/thread object to check

  ## Returns
  true if the post has Zenodo archive, false otherwise
  """
  def has_zenodo_archive?(media) do
    case get_thread_zenodo_metadata(media) do
      {:ok, _metadata} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Gets the Zenodo metadata for a thread/post if it has been archived.

  ## Parameters
  - media: The post/thread object

  ## Returns
  {:ok, metadata} if found, {:error, :not_found} if no Zenodo archive exists
  """
  def get_thread_zenodo_metadata(media) do
    # TODO: deduplicate this function and get_all_thread_zenodo_media
    # Use the `e` helper to safely access potentially unloaded associations
    # Check if media is directly attached and loaded (could be a list or single media)
    zenodo_metadata =
      case media do
        media_list when is_list(media_list) ->
          Enum.find_value(media_list, fn media ->
            e(media, :metadata, "zenodo", nil)
          end)

        %{metadata: metadata} ->
          e(metadata, "zenodo", nil)

        _ ->
          nil
      end

    if zenodo_metadata do
      {:ok, zenodo_metadata}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Gets the media record that contains Zenodo metadata for a given post.

  ## Parameters
  - post: The post/activity to check for Zenodo metadata

  ## Returns
  {:ok, media_record, metadata} or {:error, :not_found}
  """
  def get_thread_zenodo_media(media) do
    case get_all_thread_zenodo_media(media) do
      [] ->
        {:error, :not_found}

      media_items ->
        # FIXME: not necessary if we store only one Media per archived post, regardless of how many versions 
        # Get the most recent item by deposit ID (higher = newer) with timestamp fallback
        case Enum.max_by(media_items, &get_media_sort_key/1, fn -> nil end) do
          nil ->
            {:error, :not_found}

          {media_record, zenodo_metadata} ->
            {:ok, media_record, zenodo_metadata}
        end
    end
  end

  @doc """
  Gets all media items with Zenodo metadata from a post.
  Returns a list of {media, zenodo_metadata} tuples.
  """
  def get_all_thread_zenodo_media(media) do
    # TODO: deduplicate this function and get_thread_zenodo_metadata
    media
    |> flood("input_media")

    # Check if media is directly attached and loaded (could be a list or single media)
    case media do
      media_list when is_list(media_list) ->
        media_list
        |> Enum.map(fn
          %{metadata: %{"zenodo" => zenodo_metadata}} = media ->
            {media, zenodo_metadata}

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      %{metadata: %{"zenodo" => zenodo_metadata}} = media ->
        [{media, zenodo_metadata}]

      _ ->
        []
    end
    |> flood("all_zen_media")
  end

  # Helper function to determine sort key for media items (newer deposits have higher IDs)
  defp get_media_sort_key({media, zenodo_metadata}) do
    case e(zenodo_metadata, "id", nil) do
      id when is_number(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int_id, ""} -> int_id
          _ -> get_timestamp_fallback(media)
        end

      _ ->
        get_timestamp_fallback(media)
    end
  end

  defp get_timestamp_fallback(media) do
    case e(media, :inserted_at, nil) do
      %DateTime{} = datetime ->
        DateTime.to_unix(datetime)

      %NaiveDateTime{} = naive_datetime ->
        NaiveDateTime.to_erl(naive_datetime)
        |> :calendar.datetime_to_gregorian_seconds()

      _ ->
        0
    end
  end

  @doc """
  Extracts DOI and deposit information from Zenodo metadata.

  ## Parameters
  - metadata: The metadata map from get_thread_zenodo_metadata/1

  ## Returns
  %{doi: doi, deposit_id: id, is_published: boolean} or nil
  """
  def extract_zenodo_info(zenodo_data) when is_map(zenodo_data) and zenodo_data != %{} do
    doi =
      e(zenodo_data, "doi", nil) ||
        e(zenodo_data, "doi_url", nil) ||
        e(zenodo_data, "metadata", "prereserve_doi", "doi", nil)

    %{
      doi: doi,
      deposit_id:
        e(zenodo_data, "id", nil) ||
          e(zenodo_data, "conceptrecid", nil) ||
          e(zenodo_data, "record_id", nil) ||
          extract_deposit_id_from_doi(doi),
      is_published:
        e(zenodo_data, "state", nil) == "done" ||
          e(zenodo_data, "published", nil) != nil ||
          (doi != nil && String.contains?(to_string(doi), "zenodo."))
    }
  end

  def extract_zenodo_info(_metadata), do: nil

  @doc """
  Extracts deposit ID from DOI URL.

  ## Examples
      iex> extract_deposit_id_from_doi("10.5072/zenodo.318466")
      "318466"
      
      iex> extract_deposit_id_from_doi("https://doi.org/10.5072/zenodo.318466")
      "318466"
      
      iex> extract_deposit_id_from_doi("invalid")
      nil
  """
  def extract_deposit_id_from_doi(nil), do: nil

  def extract_deposit_id_from_doi(doi) when is_binary(doi) do
    case Regex.run(~r/zenodo\.(\d+)/, doi) do
      [_match, deposit_id] -> deposit_id
      _ -> nil
    end
  end

  def extract_deposit_id_from_doi(_), do: nil

  # Helper function to extract DOI from Zenodo deposit response
  def extract_doi_from_deposit(published) do
    e(published, "doi_url", nil) ||
      if doi =
           e(published, "pids", "doi", "identifier", nil) ||
             e(published, "metadata", "prereserve_doi", "doi", nil) do
        "https://doi.org/#{doi}"
      end
  end

  defp prepare_upload_data(file_input, filename) do
    cond do
      is_binary(file_input) ->
        # Handle file path - pass directly to Req
        if File.exists?(file_input) do
          final_filename = filename || Path.basename(file_input)
          # Req can handle file paths directly for streaming
          {:ok, {final_filename, file_input}}
        else
          {:error, :enoent}
        end

      Enumerable.impl_for(file_input) ->
        # Handle stream - convert to binary - FIXME: we should be able to stream this to Req directly
        final_filename = filename || "stream_upload"
        stream_content = file_input |> Enum.join()
        {:ok, {final_filename, stream_content}}

      true ->
        error(file_input, "Invalid file input")
    end
  end

  # Helper function to upload multiple files to a Zenodo deposit
  def upload_multiple_files(bucket_url, files, access_token, api_type) do
    files
    |> Enum.reduce_while({:ok, []}, fn {filename, file_data}, {:ok, acc} ->
      case Zenodo.upload_file(bucket_url, file_data, access_token, api_type, filename) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Extract Zenodo information from a DOI URL
  def extract_zenodo_info_from_doi(doi) when is_binary(doi) do
    # Extract deposit ID from Zenodo DOI URL
    # DOI format: https://doi.org/10.5072/zenodo.318716
    # or: 10.5072/zenodo.318716
    case extract_deposit_id_from_doi(doi) do
      deposit_id when is_integer(deposit_id) ->
        {:ok, %{deposit_id: deposit_id, doi: doi}}

      deposit_id when is_binary(deposit_id) ->
        case Integer.parse(deposit_id) do
          {id, ""} -> {:ok, %{deposit_id: id, doi: doi}}
          e -> error(e, "Invalid deposit ID in DOI")
        end

      e ->
        error(e, "Could not extract deposit ID from DOI")
    end
  end

  def extract_zenodo_info_from_doi(_), do: {:error, "No DOI provided"}

  def handle_zenodo_edit_workflow(
        deposit_info,
        deposit_id,
        creators,
        processed_metadata,
        access_token,
        api_type
      ) do
    is_published = deposit_info["state"] == "done" || deposit_info["doi"] != nil
    debug({is_published, api_type}, "Determining workflow type")

    cond do
      is_published and api_type == :zenodo ->
        # For published Zenodo deposits, use the "edit" action first
        edit_url = e(deposit_info, "links", "edit", nil)

        if is_nil(edit_url) do
          error("Edit URL not found in deposit links")
        else
          zenodo_edit_publish_flow(
            edit_url,
            deposit_id,
            creators,
            processed_metadata,
            access_token,
            api_type
          )
        end

      true ->
        # For unpublished records or other cases, use direct update  
        case update_deposit_metadata(
               deposit_id,
               creators,
               processed_metadata,
               access_token,
               api_type
             ) do
          {:ok, result} ->
            {:ok, "metadata updated directly"}

          {:error, reason} ->
            error(reason, "Direct metadata update failed")
            {:error, reason}
        end
    end
  end

  def zenodo_edit_publish_flow(
        edit_url,
        deposit_id,
        creators,
        processed_metadata,
        access_token,
        api_type
      ) do
    debug({edit_url, deposit_id}, "Starting zenodo_edit_publish_flow")

    processed_metadata =
      processed_metadata
      # to avoid this when editing: A validation error occurred. pids.doi: The prefix '10.5072' is managed by Zenodo. Please supply an external DOI or select 'No' to have a DOI generated for you
      |> Map.drop(["doi", "doi_url"])

    with {:ok, %{body: edit_response, status: edit_status}} when edit_status in 200..299 <-
           Req.post(edit_url,
             json: %{},
             headers: [
               {"Accept", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ]
           ) do
      debug(edit_response, "Edit action successful")

      # Step 2: Update metadata
      case update_deposit_metadata(
             deposit_id,
             creators,
             processed_metadata,
             access_token,
             api_type
           ) do
        {:ok, update_result} ->
          debug(update_result, "Metadata update successful")

          # Step 3: Publish the deposit
          case publish_deposit(deposit_id, access_token, api_type) do
            {:ok, publish_result} ->
              debug(publish_result, "Publish successful")
              {:ok, "metadata updated and published via edit action"}

            {:error, publish_error} ->
              error(processed_metadata, "Failed to publish after metadata update")
              {:error, publish_error}
          end

        {:error, update_error} ->
          error(update_error, "Failed to update metadata after edit action")
      end
    else
      {:ok, %{status: edit_status, body: edit_body}} ->
        error({edit_status, edit_body}, "Edit action failed")

      {:error, edit_error} ->
        error(edit_error, "Edit action request failed")
    end
  end

  # Converts a Zenodo error response into a human-readable message
  def zenodo_error_to_message(errors) when is_list(errors) do
    errors
    |> Enum.map(fn
      %{"field" => field, "messages" => msgs} when is_list(msgs) ->
        "#{field}: #{Enum.join(msgs, "; ")}"

      %{"field" => field, "message" => m} ->
        "#{field}: #{m}"

      other ->
        inspect(other)
    end)
    |> Enum.join(" | ")
  end

  def zenodo_error_to_message(%{"message" => msg}), do: msg
  def zenodo_error_to_message(other), do: inspect(other)
end
