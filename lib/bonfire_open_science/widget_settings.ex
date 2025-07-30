defmodule Bonfire.OpenScience.WidgetSettings do
  @moduledoc """
  Helper module to safely handle widget settings that might have been corrupted
  with actual OpenAlex data instead of boolean values.
  """
  
  use Bonfire.Common.Utils
  
  @doc """
  Safely gets a widget setting, ensuring it returns a boolean.
  If the setting contains non-boolean data (like OpenAlex API responses),
  it returns false.
  """
  def get(setting_path, opts \\ []) do
    case Settings.get(setting_path, false, opts) do
      true -> true
      false -> false
      nil -> false
      # Handle corrupted settings that contain API data
      val when is_map(val) -> false
      val when is_list(val) -> false
      _ -> false
    end
  end
  
  @doc """
  Checks if a widget is enabled by checking both the setting and module availability.
  """
  def enabled?(setting_path, module, opts \\ []) do
    setting_enabled = get(setting_path, opts)
    
    # Debug what module_enabled? returns
    module_available = try do
      result = module_enabled?(module, opts[:current_user])
      debug(result, "module_enabled? returned for #{inspect(module)}")
      
      # Force to boolean
      case result do
        true -> true
        false -> false
        nil -> false
        _ -> false
      end
    rescue
      e ->
        error(e, "Error checking module_enabled? for #{inspect(module)}")
        false
    end
    
    # Ensure both are booleans
    setting_enabled == true && module_available == true
  end
end