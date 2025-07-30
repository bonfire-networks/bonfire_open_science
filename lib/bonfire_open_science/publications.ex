defmodule Bonfire.OpenScience.Publications do
  @moduledoc """
  Main context for scientific publications and OpenAlex data.
  Provides high-level functions for fetching author and publication data.
  """

  use Bonfire.Common.Utils
  alias Bonfire.OpenScience.OpenAlex.Client
  alias Bonfire.OpenScience.ORCID
  alias Bonfire.OpenScience

  @doc """
  Gets author information from OpenAlex for a user.
  """
  def get_author_info(user) do
    with {:ok, orcid_id} <- get_user_orcid(user),
         {:ok, author_data} <- Client.fetch_author(orcid_id) do
      {:ok, author_data}
    else
      {:error, :no_orcid} -> {:error, "No ORCID ID found for user"}
      error -> error
    end
  end

  @doc """
  Gets the most recent publication for a user.
  """
  def get_recent_publication(user) do
    with {:ok, orcid_id} <- get_user_orcid(user),
         {:ok, publication} <- Client.fetch_recent_publication(orcid_id) do
      {:ok, publication}
    else
      {:error, :no_orcid} -> {:error, "No ORCID ID found for user"}
      {:error, :no_publications_found} -> {:error, "No publications found"}
      error -> error
    end
  end

  @doc """
  Gets the most cited publication for a user.
  """
  def get_most_cited_publication(user) do
    with {:ok, orcid_id} <- get_user_orcid(user),
         {:ok, publication} <- Client.fetch_most_cited_publication(orcid_id) do
      {:ok, publication}
    else
      {:error, :no_orcid} -> {:error, "No ORCID ID found for user"}
      {:error, :no_publications_found} -> {:error, "No publications found"}
      error -> error
    end
  end

  @doc """
  Gets publication types distribution for a user.
  """
  def get_publication_types(user) do
    with {:ok, orcid_id} <- get_user_orcid(user),
         {:ok, works_by_type} <- Client.fetch_works_by_type(orcid_id) do
      {:ok, works_by_type}
    else
      {:error, :no_orcid} -> {:error, "No ORCID ID found for user"}
      error -> error
    end
  end

  @doc """
  Gets all publication data for a user in one call.
  More efficient than making individual requests.
  """
  def get_all_publication_data(user) do
    with {:ok, orcid_id} <- get_user_orcid(user) do
      # Fetch basic data concurrently
      %{author_data: author_data, works_by_type: works_by_type} =
        Client.fetch_complete_data(orcid_id)

      # Fetch publications concurrently
      tasks = [
        Task.async(fn -> {:recent_publication, Client.fetch_recent_publication(orcid_id)} end),
        Task.async(fn ->
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
    else
      {:error, :no_orcid} ->
        {:error, "No ORCID ID found for user"}
    end
  rescue
    error ->
      error(error, "Failed to fetch publication data")
      {:error, "Failed to fetch publication data"}
  end

  @doc """
  Checks which OpenAlex widgets are enabled for a user.
  """
  def enabled_widgets(user) do
    current_user = user
    
    %{
      recent_publication: Settings.get(
        [Bonfire.OpenScience, :recent_publication_widget],
        false,
        current_user: current_user
      ) == true,
      most_cited_publication: Settings.get(
        [Bonfire.OpenScience, :most_cited_publication_widget],
        false,
        current_user: current_user
      ) == true,
      author_info: Settings.get(
        [Bonfire.OpenScience, :author_info_widget],
        false,
        current_user: current_user
      ) == true,
      author_topics: Settings.get(
        [Bonfire.OpenScience, :author_topics_widget],
        false,
        current_user: current_user
      ) == true,
      publication_types: Settings.get(
        [Bonfire.OpenScience, :publication_types_widget],
        false,
        current_user: current_user
      ) == true
    }
  end

  # Private helpers

  defp get_user_orcid(user) do
    aliases = OpenScience.user_aliases(user)

    case ORCID.find_from_aliases(aliases) do
      nil -> {:error, :no_orcid}
      orcid_id -> ORCID.validate(orcid_id)
    end
  end

  defp get_publication_result(results, key) do
    case Enum.find(results, fn {result_key, _} -> result_key == key end) do
      {^key, {:ok, publication}} -> publication
      _ -> nil
    end
  end
end
