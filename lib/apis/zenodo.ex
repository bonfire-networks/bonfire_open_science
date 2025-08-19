defmodule Bonfire.OpenScience.Zenodo do
  @moduledoc """
  Zenodo API client for submitting metadata, uploading files, and creating DOIs.
  """

  use Bonfire.Common.Utils
  alias Bonfire.OpenScience

  @base_url "https://zenodo.org/api"
  @sandbox_url "https://sandbox.zenodo.org/api"
  @kc_works_url "https://works.hcommons.org/api"

  @doc """
  Creates a Zenodo deposit for a user using their stored Zenodo access token, uploads files, and publishes.

  ## Parameters
  - user: The user who owns the Zenodo credentials
  - metadata: Map containing deposit metadata
  - opts: Additional options (eg. auto_publish: true/false)

  ## Returns
  {:ok, deposit} on success, {:error, reason} on failure
  """
  def publish_deposit_for_user(user, metadata, files, opts \\ []) do
    with {:ok, access_token, base_url} <- get_user_zenodo_token(user),
         {:ok, result} <- create_and_upload(metadata, files, {access_token, base_url}, opts) do
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
        if token = System.get_env("KCWORKS_PERSONAL_TOKEN") do
          {:ok, token, @kc_works_url}
        else
          {:error, :no_zenodo_credentials}
        end

      zenodo_media ->
        access_token = e(zenodo_media, :metadata, "zenodo", "access_token", nil)

        if access_token && access_token != "" do
          {:ok, access_token, nil}
        else
          {:error, :invalid_zenodo_credentials}
        end
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
  def create_and_upload(metadata, files, access_token, opts \\ []) do
    with {:ok, deposit} <- create_deposit(metadata, access_token, opts),
         bucket_url = e(deposit, "links", "bucket", nil),
         {:ok, file_infos} <- upload_files(bucket_url, files, access_token),
         deposit_id = e(deposit, "id", nil),
         result = %{deposit: deposit, files: file_infos} do
      {:ok, Map.put(result, :published, maybe_publish(deposit_id, access_token, opts))}
    end
  end

  def maybe_publish(deposit_id, access_token, opts \\ []) do
    if Keyword.get(opts, :auto_publish, true) do
      case publish_deposit(deposit_id, access_token, opts) do
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
  def create_deposit(metadata, access_token, opts \\ []) do
    url = build_url("/deposit/depositions", access_token, opts)
    debug(url, "Zenodo API URL")

    payload = %{"metadata" => metadata}

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.post(url,
             json: payload,
             headers: [
               {"Accept", "application/json"}
             ]
           ) do
      {:ok, body}
    else
      {:error, %Jason.EncodeError{}} ->
        error("Failed to encode metadata as JSON")
        {:error, :invalid_metadata}

      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo API error: #{status}")
        {:error, :zenodo_api_error}

      {:error, reason} ->
        error(reason, "HTTP request failed")
        {:error, :request_failed}
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
  def upload_file(bucket_url, file_input, access_token, filename \\ nil) do
    with {:ok, {final_filename, file_data}} <- prepare_upload_data(file_input, filename),
         upload_url = "#{bucket_url}/#{final_filename}?access_token=#{access_token}",
         {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.put(upload_url,
             body: file_data,
             headers: [
               {"Content-Type", "application/octet-stream"}
             ]
           ) do
      {:ok, body}
    else
      {:error, :enoent} ->
        error(file_input, "File to be uploaded not found")
        {:error, :file_not_found}

      {:ok, %{status: status, body: body}} ->
        error(body, "File upload to Zenodo failed: #{status}")

      {:error, reason} ->
        error(reason, "File upload to Zenodo failed")
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
  def publish_deposit(deposit_id, access_token, opts \\ []) do
    url = build_url("/deposit/depositions/#{deposit_id}/actions/publish", access_token, opts)

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.post(url,
             body: "",
             headers: [
               {"Content-Type", "application/json"},
               {"Accept", "application/json"}
             ]
           ) do
      {:ok, body}
    else
      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo publish error: #{status}")
        {:error, :publish_failed}

      {:error, reason} ->
        error(reason, "Publish request failed")
        {:error, :request_failed}
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
  def get_deposit(deposit_id, access_token, opts \\ []) do
    url = build_url("/deposit/depositions/#{deposit_id}", access_token, opts)

    with {:ok, %{body: body, status: status}} when status in 200..299 <-
           Req.get(url, headers: [{"Accept", "application/json"}]) do
      {:ok, body}
    else
      {:ok, %{status: status, body: body}} ->
        error(body, "Zenodo API error: #{status}")
        {:error, :zenodo_api_error}

      {:error, reason} ->
        error(reason, "HTTP request failed")
        {:error, :request_failed}
    end
  end

  # Private helper functions

  defp build_url(path, access_token, opts \\ [])

  defp build_url(path, {access_token, base_url}, opts) do
    if is_binary(base_url) do
      "#{base_url}#{path}?access_token=#{access_token}"
    else
      build_url(path, access_token, opts)
    end
  end

  defp build_url(path, access_token, opts) do
    base_url = if System.get_env("ZENODO_ENV") == "sandbox", do: @sandbox_url, else: @base_url
    build_url(path, {access_token, base_url}, opts)
  end

  defp upload_files(bucket_url, files, access_token) do
    files
    |> normalize_file_list()
    |> Enum.reduce_while({:ok, []}, fn {filename, file_input}, {:ok, acc} ->
      case upload_file(bucket_url, file_input, access_token, filename) do
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
