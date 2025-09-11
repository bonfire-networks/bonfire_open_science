defmodule Bonfire.OpenScience.Publications do
  @moduledoc """
  Main context for scientific publications and OpenAlex data.
  Provides high-level functions for fetching author and publication data.
  """

  use Bonfire.Common.Utils
  alias Bonfire.OpenScience.OpenAlex.Client
  alias Bonfire.OpenScience.ORCID
  alias Bonfire.OpenScience
  alias Bonfire.Common.Cache
  alias Bonfire.Common.Settings

  # 3 hours
  @default_cache_ttl 1_000 * 60 * 60 * 3

  @doc """
  Gets author information from OpenAlex for a user with caching.
  """
  def get_author_info(user) do
    with {:ok, orcid_id} <- ORCID.user_orcid_id(user) do
      Cache.maybe_apply_cached(
        &Client.fetch_author/1,
        [orcid_id],
        cache_key: "openalex_author:#{orcid_id}",
        expire: @default_cache_ttl
      )
    else
      {:error, :no_orcid} -> {:error, "No ORCID ID found for user"}
      error -> error
    end
  end

  @doc """
  Gets the most recent publication for a user with caching.
  """
  def get_recent_publication(user) do
    with {:ok, orcid_id} <- ORCID.user_orcid_id(user) do
      Cache.maybe_apply_cached(
        &Client.fetch_recent_publication/1,
        [orcid_id],
        cache_key: "openalex_recent:#{orcid_id}",
        expire: @default_cache_ttl
      )
    else
      {:error, :no_orcid} -> {:error, "No ORCID ID found for user"}
      error -> error
    end
  end

  @doc """
  Gets the most cited publication for a user with caching.
  """
  def get_most_cited_publication(user) do
    with {:ok, orcid_id} <- ORCID.user_orcid_id(user) do
      Cache.maybe_apply_cached(
        &Client.fetch_most_cited_publication/1,
        [orcid_id],
        cache_key: "openalex_cited:#{orcid_id}",
        expire: @default_cache_ttl
      )
    else
      {:error, :no_orcid} -> {:error, "No ORCID ID found for user"}
      error -> error
    end
  end

  @doc """
  Gets publication types distribution for a user with caching.
  """
  def get_publication_types(user) do
    with {:ok, orcid_id} <- ORCID.user_orcid_id(user) do
      Cache.maybe_apply_cached(
        &Client.fetch_works_by_type/1,
        [orcid_id],
        cache_key: "openalex_types:#{orcid_id}",
        expire: @default_cache_ttl
      )
    else
      {:error, :no_orcid} -> {:error, "No ORCID ID found for user"}
      error -> error
    end
  end

  @doc """
  Gets all publication data for a user in one call with caching.
  More efficient than making individual requests.
  """
  def get_all_publication_data(user) do
    with {:ok, orcid_id} <- ORCID.user_orcid_id(user) do
      Cache.maybe_apply_cached(
        &fetch_complete_data_uncached/1,
        [orcid_id],
        cache_key: "openalex_complete:#{orcid_id}",
        expire: @default_cache_ttl
      )
    else
      {:error, :no_orcid} ->
        {:error, "No ORCID ID found for user"}
    end
  end

  # Private function that actually fetches all data
  defp fetch_complete_data_uncached(orcid_id) do
    # Fetch basic data concurrently
    %{author_data: author_data, works_by_type: works_by_type} =
      Client.fetch_complete_data(orcid_id)

    # Fetch publications concurrently  
    tasks = [
      apply_task(:async, fn ->
        {:recent_publication, Client.fetch_recent_publication(orcid_id)}
      end),
      apply_task(:async, fn ->
        {:most_cited_publication, Client.fetch_most_cited_publication(orcid_id)}
      end)
    ]

    publication_results = Task.await_many(tasks, 15_000)

    {:ok,
     %{
       author_data: author_data,
       works_by_type: works_by_type || [],
       recent_publication: get_publication_result(publication_results, :recent_publication),
       most_cited_publication:
         get_publication_result(publication_results, :most_cited_publication)
     }}
  rescue
    error ->
      error(error, "Failed to fetch publication data")
      {:error, "Failed to fetch publication data"}
  end

  @doc """
  Checks which OpenAlex widgets are enabled for a user.
  """
  def enabled_widgets(user) do
    %{
      recent_publication:
        Settings.get(
          [Bonfire.OpenScience, :recent_publication_widget],
          false,
          current_user: user
        ) == true,
      most_cited_publication:
        Settings.get(
          [Bonfire.OpenScience, :most_cited_publication_widget],
          false,
          current_user: user
        ) == true,
      author_info:
        Settings.get(
          [Bonfire.OpenScience, :author_info_widget],
          false,
          current_user: user
        ) == true,
      author_topics:
        Settings.get(
          [Bonfire.OpenScience, :author_topics_widget],
          false,
          current_user: user
        ) == true,
      publication_types:
        Settings.get(
          [Bonfire.OpenScience, :publication_types_widget],
          false,
          current_user: user
        ) == true
    }
  end

  @doc """
  Invalidates cached OpenAlex data for a user.
  """
  def invalidate_user_cache(user) do
    case ORCID.user_orcid_id(user) do
      {:ok, orcid_id} ->
        Cache.reset(&Client.fetch_author/1, [orcid_id])
        Cache.reset(&Client.fetch_recent_publication/1, [orcid_id])
        Cache.reset(&Client.fetch_most_cited_publication/1, [orcid_id])
        Cache.reset(&Client.fetch_works_by_type/1, [orcid_id])
        Cache.reset(&fetch_complete_data_uncached/1, [orcid_id])
        :ok

      _ ->
        :ok
    end
  end

  # Private helpers

  defp get_publication_result(results, key) do
    case Enum.find(results, fn {result_key, _} -> result_key == key end) do
      {^key, {:ok, publication}} -> publication
      _ -> nil
    end
  end
end
