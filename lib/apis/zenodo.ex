defmodule Bonfire.OpenScience.Zenodo do
  @moduledoc """
  Zenodo API client for submitting metadata, uploading files, and creating DOIs.
  """

  use Bonfire.Common.Utils
  alias Bonfire.OpenScience

  @base_url "https://zenodo.org/api"
  @sandbox_url "https://sandbox.zenodo.org/api"

  @doc """
  Creates a Zenodo deposit for a user using their stored Zenodo access token.

  ## Parameters
  - user: The user who owns the Zenodo credentials
  - metadata: Map containing deposit metadata
  - opts: Additional options (eg. auto_publish: true/false)

  ## Returns
  {:ok, deposit} on success, {:error, reason} on failure
  """
  def create_deposit_for_user(user, metadata, opts \\ []) do
    with {:ok, access_token} <- get_user_zenodo_token(user),
         {:ok, deposit} <- create_deposit(metadata, access_token, opts) do
      deposit_id = e(deposit, "id", nil)

      {:ok, %{deposit: deposit, published: maybe_publish(deposit_id, access_token, opts)}}
    end
  end

  @doc """
  Gets the Zenodo access token for a user from their stored media.

  ## Parameters
  - user: The user to get the token for

  ## Returns
  {:ok, access_token} on success, {:error, reason} on failure
  """
  def get_user_zenodo_token(user) do
    case OpenScience.user_alias_by_type(user, "zenodo") do
      nil ->
        {:error, :no_zenodo_credentials}

      zenodo_media ->
        access_token = e(zenodo_media, :metadata, "zenodo", "access_token", nil)

        if access_token && access_token != "" do
          {:ok, access_token}
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
         bucket_url = e(deposit, "links", "bucket"),
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

    with {:ok, json_payload} <- Jason.encode(payload),
         {:ok, %{body: body, status: status}} when status in 200..299 <-
           HTTP.post(url, json_payload, [
             {"Content-Type", "application/json"},
             {"Accept", "application/json"}
           ]),
         {:ok, deposit} <- Jason.decode(body) do
      {:ok, deposit}
    else
      {:error, %Jason.EncodeError{}} ->
        error("Failed to encode metadata as JSON")
        {:error, :invalid_metadata}

      {:ok, %{status: status, body: body}} ->
        error("Zenodo API error: #{status} - #{body}")
        {:error, :zenodo_api_error}

      {:error, reason} ->
        error("HTTP request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  @doc """
  Uploads a file to an existing Zenodo deposit using the new files API.

  ## Parameters
  - bucket_url: The bucket URL from the deposit's links
  - file_path: Local path to the file to upload
  - filename: Name to give the file in Zenodo (optional, defaults to basename of file_path)
  - access_token: Zenodo API access token

  ## Returns
  {:ok, file_info} on success, {:error, reason} on failure
  """
  def upload_file(bucket_url, file_path, access_token, filename \\ nil) do
    filename = filename || Path.basename(file_path)
    upload_url = "#{bucket_url}/#{filename}?access_token=#{access_token}"

    with {:ok, file_data} <- File.read(file_path),
         {:ok, %{body: body, status: status}} when status in 200..299 <-
           HTTP.put(upload_url, file_data, [
             {"Content-Type", "application/octet-stream"}
           ]),
         {:ok, file_info} <- Jason.decode(body) do
      {:ok, file_info}
    else
      {:error, :enoent} ->
        {:error, :file_not_found}

      {:ok, %{status: status, body: body}} ->
        error("Zenodo file upload error: #{status} - #{body}")
        {:error, :upload_failed}

      {:error, reason} ->
        error("File upload failed: #{inspect(reason)}")
        {:error, :upload_failed}
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
           HTTP.post(url, "", [
             {"Content-Type", "application/json"},
             {"Accept", "application/json"}
           ]),
         {:ok, published_record} <- Jason.decode(body) do
      {:ok, published_record}
    else
      {:ok, %{status: status, body: body}} ->
        error("Zenodo publish error: #{status} - #{body}")
        {:error, :publish_failed}

      {:error, reason} ->
        error("Publish request failed: #{inspect(reason)}")
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
           HTTP.get(url, [{"Accept", "application/json"}]),
         {:ok, deposit} <- Jason.decode(body) do
      {:ok, deposit}
    else
      {:ok, %{status: status, body: body}} ->
        error("Zenodo API error: #{status} - #{body}")
        {:error, :zenodo_api_error}

      {:error, reason} ->
        error("HTTP request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  # Private helper functions

  defp build_url(path, access_token, _opts \\ []) do
    base = if System.get_env("ZENODO_ENV") == "sandbox", do: @sandbox_url, else: @base_url
    "#{base}#{path}?access_token=#{access_token}"
  end

  defp upload_files(bucket_url, files, access_token) do
    results =
      Enum.map(files, fn
        {file_path, filename} ->
          upload_file(bucket_url, file_path, access_token, filename)

        file_path when is_binary(file_path) ->
          upload_file(bucket_url, file_path, access_token)
      end)

    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {successes, []} ->
        file_infos = Enum.map(successes, fn {:ok, info} -> info end)
        {:ok, file_infos}

      {_successes, errors} ->
        {:error, {:upload_errors, errors}}
    end
  end
end
