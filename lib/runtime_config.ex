defmodule Bonfire.OpenScience.RuntimeConfig do
  use Bonfire.Common.Localise

  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  @doc """
  NOTE: you can override this default config in your app's `runtime.exs`, by placing similarly-named config keys below the `Bonfire.Common.Config.LoadExtensionsConfig.load_configs()` line
  """
  def config do
    import Config

    # config :bonfire_open_science,
    #   modularity: :disabled

    config :bonfire, :ui,
      profile: [
        navigation: [
          objects: [media: l("Publications")]
        ]
      ]

    config :bonfire_social_graph, Bonfire.Social.Graph.Aliases,
      triggers: [
        add_link: [
          orcid: Bonfire.OpenScience.APIs
        ]
      ]

    config :unfurl,
      ignore_redirect_urls: [
        "https://orcid.org/signin"
      ]

    config :unfurl, Unfurl.Oembed,
      extra_providers: [
        %{
          "provider_name" => "Wikibase or Crossref",
          "provider_url" => "wikipedia.org",
          "fetch_function" => {Bonfire.OpenScience.APIs, :fetch},
          "endpoints" => [
            %{
              "schemes" =>
                [
                  fn url ->
                    case URI.parse(url) do
                      %URI{scheme: nil} -> false
                      %URI{host: nil} -> false
                      %URI{path: nil} -> false
                      _ -> true
                    end
                  end
                ] ++ (Bonfire.OpenScience.APIs.pub_id_and_uri_matchers() |> Map.values())
              #      "url" => "https://api.crossref.org/works/",
              #      "append_url" => true 
            }
          ]
        }
      ]
  end
end
