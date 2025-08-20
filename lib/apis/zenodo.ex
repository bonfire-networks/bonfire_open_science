defmodule Bonfire.OpenScience.Zenodo do
  @moduledoc """
  Zenodo API client for submitting metadata, uploading files, and creating DOIs.
  """

  use Bonfire.Common.Utils
  alias Bonfire.OpenScience

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
  {:ok, access_token} on success, {:error, reason} on failure
  """
  defp get_user_zenodo_token(user) do
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
      {:ok, Map.put(result, :published, maybe_publish(deposit_id, access_token, api_type, opts))}
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

    payload =
      if api_type == :invenio do
        # massage data for the slightly more strict API
        %{
          "metadata" =>
            metadata
            |> Map.put_new("resource_type", %{"id" => "dataset"})
            |> Map.put_new("publisher", "Open Science Network")
            |> Map.put(
              "creators",
              creators
              |> Enum.map(fn creator ->
                person_or_org = %{
                  "given_name" => creator["given_name"],
                  "family_name" => creator["family_name"] || creator["name"],
                  "type" => "personal",
                  "name" =>
                    creator["name"] || "#{creator["given_name"]} #{creator["family_name"]}"
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

                affiliations =
                  case creator["affiliations"] || creator["affiliation"] do
                    affs when is_list(affs) ->
                      affs
                      |> Enum.map(fn
                        a when is_map(a) -> a["name"]
                        a -> a
                      end)
                      |> Enum.filter(&(&1 && &1 != ""))
                      |> Enum.map(&%{"name" => &1})

                    %{"name" => name} = aff when is_binary(name) and name != "" ->
                      [aff]

                    aff when is_binary(aff) and aff != "" ->
                      [%{"name" => aff}]

                    _ ->
                      []
                  end

                if affiliations != [] do
                  %{"person_or_org" => person_or_org, "affiliations" => affiliations}
                else
                  %{"person_or_org" => person_or_org}
                end
              end)
            )
        }
      else
        # zenodo
        %{"metadata" => metadata |> Map.put("creators", creators)}
      end

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.post(url,
             json: payload,
             headers: [
               {"Accept", "application/json"},
               {"Authorization", "Bearer #{access_token}"}
             ]
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

            {:ok, %{status: status, body: body}} ->
              error(body, "File upload to Invenio failed: #{status}")

            {:error, reason} ->
              error(reason, "File upload to Invenio failed")
          end
      end
    else
      {:error, :enoent} ->
        error(file_input, "File to be uploaded not found")

      {:error, reason} ->
        error(reason, "File upload failed")
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
      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo publish error: #{status}")

      {:error, reason} ->
        error(reason, "Publish request failed")
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
    end
  end

  # Private helper functions

  defp build_url(path_type, access_token, api_type, params \\ %{}) do
    case {api_type, path_type} do
      {:zenodo, :deposit} ->
        "#{zenodo_base_url()}/deposit/depositions"

      {:zenodo, :upload_file} ->
        "#{params[:bucket_url]}/#{params[:filename]}"

      {:zenodo, :publish} ->
        "#{zenodo_base_url()}/deposit/depositions/#{params[:id]}/actions/publish"

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
end
