defmodule IecWeb.Params do
  @moduledoc "Reads values from URLs, which anyone can type."

  @doc "A whole-number id from a URL segment, or nil when it is not one (`/wards/abc`)."
  def id(text) when is_binary(text) do
    case Integer.parse(text) do
      {id, ""} -> id
      _not_an_id -> nil
    end
  end

  def id(_other), do: nil
end
