defmodule Iec.Seed do
  @moduledoc """
  Fills the database in one go, without waiting for the pollers: party names, the
  previous election's final results, the live election's results so far, every followed
  party's files for both elections, and the ward directory.

  The app does all of this on its own when it starts (see `Iec.Application`); this is for
  filling a fresh database up front, or after the count when nothing is being polled.
  Every step is idempotent, so running it again only adds what changed.
  """

  alias Iec.{Parties, Results}
  alias Iec.Results.Feed

  def run(report \\ &IO.puts/1) do
    live = Feed.live_election()
    previous = Feed.previous_election()

    report.("Party names and colours")
    Results.refresh_parties()

    report.("#{previous.year} results")
    Results.import_previous_election()

    report.("#{live.year} results")
    for feed <- Feed.feeds(live), do: Results.import_feed(feed)

    party_ids = national_party_ids()
    report.("Party files for #{length(party_ids)} parties")

    for party_id <- party_ids do
      Parties.import_party_file(live, party_id)

      unless Parties.party_file_imported?(previous, party_id) do
        Parties.import_party_file(previous, party_id)
      end
    end

    report.("Ward directory (one file per municipality, a few minutes)")
    Parties.import_ward_directory()

    report.("Done")
    :ok
  end

  defp national_party_ids do
    case Results.get_latest_snapshot(:national, 0) do
      nil -> []
      national -> for party <- national.party_results, party.party_id >= 0, do: party.party_id
    end
  end
end
