defmodule Iec.Seed do
  @moduledoc """
  Fills the database in one go, without waiting for the pollers: party names, both
  elections' results, the map outlines, every municipality file (which wards belong where,
  every party standing, and the previous election's ward results), and the files of every
  party standing for both elections.

  The app does all of this on its own when it starts (see `Iec.Application`); this is for
  filling a fresh database up front, or after the count when nothing is being polled.
  Every step is idempotent, so running it again only adds what changed.
  """

  alias Iec.{Maps, Places, Results}
  alias Iec.Parties.Import
  alias Iec.Results.Feed

  def run(report \\ &IO.puts/1) do
    live = Feed.live_election()
    previous = Feed.previous_election()

    report.("Party names and colours")
    Results.refresh_parties()

    report.("#{previous.year} results")
    Results.import_previous_election()

    report.("Earlier elections, for the trends")
    Results.import_history()

    report.("#{live.year} results")
    for feed <- Feed.feeds(live), do: Results.import_feed(feed)
    Import.follow_national_parties()

    report.("Map outlines (provinces, municipalities, wards; about 80 MB)")
    Maps.import_boundaries()

    report.("Town and suburb names (OpenStreetMap, through the Overpass API; four queries)")
    report.("  #{inspect(Places.import_places())}")

    report.("#{live.year} municipality files: wards and every party standing (a few minutes)")
    Import.import_municipality_files()

    report.("#{previous.year} municipality files: every ward's result (a few minutes)")
    Import.import_previous_ward_results()

    party_ids = Import.list_followed_party_ids()
    report.("#{live.year} files of #{length(party_ids)} parties")
    for party_id <- party_ids, do: Import.import_party_file(live, party_id)

    report.("#{previous.year} party files")
    Import.import_previous_party_files()

    report.("Done")
    :ok
  end
end
