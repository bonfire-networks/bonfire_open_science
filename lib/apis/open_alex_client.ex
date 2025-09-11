defmodule Bonfire.OpenScience.OpenAlex.Client do
  @moduledoc """
  HTTP client for OpenAlex API interactions.
  Handles all direct API calls to OpenAlex endpoints.
  """

  use Bonfire.Common.Utils
  import Untangle

  @base_url "https://api.openalex.org"
  @default_timeout [timeout: 10_000, recv_timeout: 10_000]

  @doc """
  Fetches author data from OpenAlex by ORCID ID.
  Returns {:ok, author_data} or {:error, reason}
  """
  def fetch_author(orcid_id) when is_binary(orcid_id) do
    url = "#{@base_url}/authors/orcid:#{orcid_id}"

    case HTTP.get(url, [], @default_timeout) do
      {:ok, %{body: body}} ->
        Jason.decode(body)

      error ->
        error(error, "Failed to fetch author data from OpenAlex")
        {:error, :api_request_failed}
    end
  end

  @doc """
  Fetches works grouped by type for an author by ORCID ID.
  Returns {:ok, works_by_type} or {:error, reason}
  """
  def fetch_works_by_type(orcid_id) when is_binary(orcid_id) do
    url = "#{@base_url}/works?filter=authorships.author.orcid:#{orcid_id}&group_by=type"

    case HTTP.get(url, [], @default_timeout) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"group_by" => groups}} ->
            works =
              Enum.map(groups, fn group ->
                %{
                  "display_name" => e(group, "key_display_name", "") |> String.capitalize(),
                  "count" => e(group, "count", 0)
                }
              end)
              |> Enum.sort_by(fn item -> -e(item, "count", 0) end)

            {:ok, works}

          {:ok, _} ->
            {:ok, []}

          error ->
            error
        end

      error ->
        error(error, "Failed to fetch works by type from OpenAlex")
        {:error, :api_request_failed}
    end
  end

  @doc """
  Fetches the most recent publication for an author by ORCID ID.
  Returns {:ok, publication} or {:error, reason}
  """
  def fetch_recent_publication(orcid_id) when is_binary(orcid_id) do
    url =
      "#{@base_url}/works?filter=authorships.author.orcid:#{orcid_id}&sort=publication_date:desc&per-page=1"

    fetch_single_work(url, "recent publication")
  end

  @doc """
  Fetches the most cited publication for an author by ORCID ID.
  Returns {:ok, publication} or {:error, reason}
  """
  def fetch_most_cited_publication(orcid_id) when is_binary(orcid_id) do
    url =
      "#{@base_url}/works?filter=authorships.author.orcid:#{orcid_id}&sort=cited_by_count:desc&per-page=1"

    fetch_single_work(url, "most cited publication")
  end

  @doc """
  Fetches complete data for an author including author info and works by type.
  Uses concurrent requests for better performance.
  """
  def fetch_complete_data(orcid_id) when is_binary(orcid_id) do
    tasks = [
      apply_task(:async, fn -> {:author_data, fetch_author(orcid_id)} end),
      apply_task(:async, fn -> {:works_by_type, fetch_works_by_type(orcid_id)} end)
    ]

    results = Task.await_many(tasks, 15_000)

    %{
      author_data: get_task_result(results, :author_data),
      works_by_type: get_task_result(results, :works_by_type, [])
    }
  rescue
    error ->
      error(error, "Failed to fetch complete OpenAlex data")
      %{author_data: nil, works_by_type: []}
  end

  # Private helpers

  defp fetch_single_work(url, work_type) do
    case HTTP.get(url, [], @default_timeout) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"results" => [publication | _]}} ->
            {:ok, publication}

          {:ok, %{"results" => []}} ->
            {:error, :no_publications_found}

          error ->
            error
        end

      error ->
        error(error, "Failed to fetch #{work_type} from OpenAlex")
        {:error, :api_request_failed}
    end
  end

  defp get_task_result(results, key, default \\ nil) do
    case Enum.find(results, fn {result_key, _} -> result_key == key end) do
      {^key, {:ok, value}} -> value
      {^key, {:error, _}} -> default
      _ -> default
    end
  end
end
