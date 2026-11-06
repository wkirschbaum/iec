defmodule Iec.Parties do
  @moduledoc """
  Party-level results: each party's share and seats per municipality and per ward, from
  the IEC's per-party files, and how that compares with the previous election. The files
  are read in by `Iec.Parties.Import`; this module reads the stored rows back for the
  party, council, ward and movers pages.

  Holders (who won a ward or controls a council) are known among the parties whose files
  are stored, which is every party standing.
  """

  import Ecto.Query

  alias Iec.{Maps, Repo, Results}
  alias Iec.Parties.Import
  alias Iec.Results.{Fetch, PartyMunicipalityResult, PartyWardResult, Ward}

  @topic "parties"

  @doc "Subscribes the caller to `{:party_results_changed, party_id}` and `:wards_mapped`."
  def subscribe, do: Phoenix.PubSub.subscribe(Iec.PubSub, @topic)

  @doc "Announces that a party's rows changed."
  def broadcast_changed(party_id), do: broadcast({:party_results_changed, party_id})

  @doc "Announces that municipality files were read: wards are mapped, holders known."
  def broadcast_wards_mapped, do: broadcast(:wards_mapped)

  # Party files change several times a second during the count, so cached page data goes
  # stale at most once per half second; pages refresh later than that after a broadcast.
  defp broadcast(message) do
    Iec.Cache.invalidate_soon()
    Phoenix.PubSub.broadcast(Iec.PubSub, @topic, message)
  end

  @doc "Stores a party file; see `Iec.Parties.Import.ingest/4`."
  defdelegate ingest(feed, data, body, validators), to: Import

  ## Party page

  @doc """
  Everything the party page shows: national figures now and in the previous election,
  and each municipality and ward the party contested in either, classified as gained,
  lost, kept/held or still pending.
  """
  def get_party_overview(party_id) do
    live_year = Results.live_year()
    previous_year = Results.previous_year()
    years = [live_year, previous_year]
    municipality_rows = party_rows(PartyMunicipalityResult, party_id, :municipality_id, years)
    ward_rows = party_rows(PartyWardResult, party_id, :ward_id, years)
    areas = Results.list_area_summaries(:municipality)

    %{
      party_id: party_id,
      national: national_row(party_id, live_year),
      previous_national: national_row(party_id, previous_year),
      municipalities:
        compare_municipalities(
          municipality_rows[live_year] || %{},
          municipality_rows[previous_year] || %{},
          areas
        ),
      wards: compare_wards(ward_rows[live_year] || %{}, ward_rows[previous_year] || %{}, areas)
    }
  end

  defp national_row(party_id, year) do
    case Results.get_latest_snapshot(:national, 0, election: year) do
      nil -> nil
      snapshot -> Enum.find(snapshot.party_results, &(&1.party_id == party_id))
    end
  end

  # A party's rows per election, each keyed by `key` (municipality or ward id).
  defp party_rows(schema, party_id, key, years) do
    schema
    |> where([row], row.election in ^years and row.party_id == ^party_id)
    |> Repo.all()
    |> Enum.group_by(& &1.election)
    |> Map.new(fn {election, rows} -> {election, Map.new(rows, &{Map.fetch!(&1, key), &1})} end)
  end

  defp compare_municipalities(now_by_id, before_by_id, areas) do
    live_year = Results.live_year()
    previous_year = Results.previous_year()
    municipality_ids = Enum.uniq(Map.keys(now_by_id) ++ Map.keys(before_by_id))
    control = get_council_control(municipality_ids)

    municipality_ids
    |> Enum.map(fn municipality_id ->
      now = now_by_id[municipality_id]
      before = before_by_id[municipality_id]
      control_now = control[{live_year, municipality_id}]

      area =
        areas[municipality_id] ||
          %{name: "Municipality #{municipality_id}", province_id: nil, complete: false}

      majority_now = now != nil and now.majority
      majority_before = before != nil and before.majority

      status =
        cond do
          majority_now and majority_before -> :kept
          majority_now -> :gained
          majority_before and not area.complete -> :pending
          majority_before and control_now != nil and control_now.majority != nil -> :lost_to_party
          majority_before -> :lost_hung
          true -> :none
        end

      %{
        municipality_id: municipality_id,
        name: area.name,
        province_id: area.province_id,
        complete: area.complete,
        status: status,
        share: now && now.vote_percentage,
        previous_share: before && before.vote_percentage,
        swing: swing(now, before),
        seats: now && now.seats_won,
        previous_seats: before && before.seats_won,
        control: control_now,
        previous_control: control[{previous_year, municipality_id}]
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  # The party's wards, now and before. Only a comparable ward (see `ward_histories/2`) can
  # be held, gained or lost; any other can only be won (`:won_new`, and `new_ward` here
  # means new or redrawn). An abolished ward will never be declared, so it is neither
  # pending nor lost.
  defp compare_wards(now_by_id, before_by_id, areas) do
    ward_ids = Enum.uniq(Map.keys(now_by_id) ++ Map.keys(before_by_id))
    directory = ward_directory()
    municipality_for = ward_municipalities(directory)
    histories = ward_histories(ward_ids, abolished_ward_ids(ward_ids, directory))
    first_fetched_at = first_party_fetches(Results.live_year())

    ward_ids
    |> Enum.map(fn ward_id ->
      history = histories[ward_id]
      now = now_by_id[ward_id]
      before = if history.comparable, do: before_by_id[ward_id]
      won_now = now != nil and now.won
      held_before = before != nil and before.won

      status =
        cond do
          history.abolished -> :none
          won_now and held_before -> :held
          won_now and not history.comparable -> :won_new
          won_now -> :gained
          held_before and history.holder != nil -> :lost
          held_before -> :pending
          true -> :none
        end

      municipality = areas[municipality_for.(ward_id)]
      previous_holder = if history.comparable, do: history.previous_holder

      %{
        ward_id: ward_id,
        ward_number: Ward.ward_number(ward_id),
        municipality_name: (municipality && municipality.name) || "–",
        municipality_id: municipality && municipality.id,
        province_id: municipality && municipality.province_id,
        status: status,
        share: now && now.vote_percentage,
        previous_share: before && before.vote_percentage,
        swing: swing(now, before),
        previous_holder: previous_holder && previous_holder.party_id,
        new_ward: not history.comparable and not history.abolished,
        abolished: history.abolished,
        redrawn: history.redrawn
      }
      |> Map.merge(declaration(history.holder, first_fetched_at))
    end)
    |> Enum.sort_by(&{&1.municipality_name, &1.ward_number})
  end

  # A ward missing from the live directory although its municipality's file has been read
  # was abolished.
  defp abolished_ward_ids(ward_ids, directory) do
    read_codes = MapSet.new(Map.keys(directory), &Ward.municipality_code/1)

    for ward_id <- ward_ids,
        not Map.has_key?(directory, ward_id),
        Ward.municipality_code(ward_id) in read_codes,
        into: MapSet.new(),
        do: ward_id
  end

  # Ward id → municipality id for every ward in the live directory.
  defp ward_directory,
    do: Repo.all(from ward in Ward, select: {ward.id, ward.municipality_id}) |> Map.new()

  # Ward id → municipality id, from the directory, falling back to the ward's
  # municipality code for wards that only existed in the previous election.
  defp ward_municipalities(directory) do
    by_code =
      Map.new(directory, fn {ward_id, municipality_id} ->
        {Ward.municipality_code(ward_id), municipality_id}
      end)

    fn ward_id -> directory[ward_id] || by_code[Ward.municipality_code(ward_id)] end
  end

  ## Council and ward pages

  @doc """
  One council from the party files: every tracked party's share, seats and majority now
  and in the previous election (best first), and each ward's winner now and then.
  """
  def get_municipality_overview(municipality_id) do
    parties =
      PartyMunicipalityResult
      |> where([result], result.municipality_id == ^municipality_id)
      |> Repo.all()
      |> beside_previous()
      |> Enum.map(fn {now, before} ->
        Map.merge(share_fields(now, before), %{
          seats: now.seats_won,
          previous_seats: before && before.seats_won,
          majority: now.majority,
          previous_majority: before != nil and before.majority
        })
      end)
      |> Enum.sort_by(&(-(&1.share || 0)))

    ward_ids =
      Repo.all(
        from ward in Ward,
          where: ward.municipality_id == ^municipality_id,
          order_by: ward.id,
          select: ward.id
      )

    %{parties: parties, wards: ward_winners(ward_ids)}
  end

  @doc """
  One ward now and in the previous election, from the party files, or nil for a ward not
  in the live ward directory:

    * the ward (`ward_id`, `ward_number`, `municipality_id`) and its winner as on the
      municipality page (`holder`, `share`, `declared_at`, `previous_holder`,
      `changed_hands`, `new_ward`, `redrawn`)
    * `parties` – every followed party's share now and before and its swing, biggest
      first; `won` and `previous_won` mark the winners. A redrawn ward's previous figures
      are for its old shape. `council_share` is the party's share of the whole council.
  """
  def get_ward_overview(ward_id) do
    case Repo.get(Ward, ward_id) do
      nil ->
        nil

      ward ->
        [summary] = ward_winners([ward.id])

        council_shares =
          Repo.all(
            from result in PartyMunicipalityResult,
              where:
                result.municipality_id == ^ward.municipality_id and
                  result.election == ^Results.live_year(),
              select: {result.party_id, result.vote_percentage}
          )
          |> Map.new()

        # Parties standing elsewhere but with nothing here, now or before, are left out.
        parties =
          PartyWardResult
          |> where([result], result.ward_id == ^ward.id)
          |> Repo.all()
          |> beside_previous()
          |> Enum.map(fn {now, before} ->
            Map.merge(share_fields(now, before), %{
              won: now.won,
              previous_won: before != nil and before.won,
              council_share: council_shares[now.party_id]
            })
          end)
          |> Enum.filter(&(&1.won or (&1.share || 0) > 0 or (&1.previous_share || 0) > 0))
          |> Enum.sort_by(&{not &1.won, -(&1.share || 0)})

        Map.merge(summary, %{municipality_id: ward.municipality_id, parties: parties})
    end
  end

  # Each live ward's winner now and before, and whether it changed hands. These wards are
  # in the live directory, so none is abolished; `new_ward` means it had no results at
  # all in the previous election.
  defp ward_winners(ward_ids) do
    histories = ward_histories(ward_ids)
    first_fetched_at = first_party_fetches(Results.live_year())

    for ward_id <- ward_ids do
      %{holder: holder, previous_holder: previous_holder} = history = histories[ward_id]

      %{
        ward_id: ward_id,
        ward_number: Ward.ward_number(ward_id),
        share: holder && holder.vote_percentage,
        previous_holder: previous_holder && previous_holder.party_id,
        previous_share: previous_holder && previous_holder.vote_percentage,
        # A redrawn ward shows who held its old shape, but did not change hands as such.
        changed_hands:
          history.comparable and holder != nil and holder.party_id != previous_holder.party_id,
        new_ward: not history.existed,
        redrawn: history.redrawn
      }
      |> Map.merge(declaration(holder, first_fetched_at))
    end
  end

  # Rows of both elections paired by party: `{now, before}` for each party with a live
  # row, `before` nil when it had none.
  defp beside_previous(rows) do
    by_election = Enum.group_by(rows, & &1.election)
    before_by_party = Map.new(by_election[Results.previous_year()] || [], &{&1.party_id, &1})

    for now <- by_election[Results.live_year()] || [],
        do: {now, before_by_party[now.party_id]}
  end

  defp share_fields(now, before) do
    %{
      party_id: now.party_id,
      share: now.vote_percentage,
      previous_share: before && before.vote_percentage,
      swing: swing(now, before)
    }
  end

  ## Movers

  @doc """
  Who is up and who is down since the previous election:

    * `parties` – every party on the national list with its share now and before, its
      swing (a new party swings from zero), and the wards and council majorities it
      gained and lost
    * `local_swings` – the largest rises and falls of a party within one council
      (`%{rises: [...], falls: [...]}`, ten each)

  Wards count once declared; councils once their count is complete. Holders are known for
  parties whose files are stored.
  """
  def get_movers do
    areas = Results.list_area_summaries(:municipality)
    national = Results.get_latest_snapshot(:national, 0)
    previous = Results.get_latest_snapshot(:national, 0, election: Results.previous_year())
    previous_by_party = Map.new((previous && previous.party_results) || [], &{&1.party_id, &1})
    wards = ward_turnover()
    councils = council_turnover(areas)

    parties =
      for party <- (national && national.party_results) || [], party.party_id >= 0 do
        before = previous_by_party[party.party_id]
        tally = fn turnover, key -> get_in(turnover, [party.party_id, key]) || 0 end

        %{
          party_id: party.party_id,
          share: party.vote_percentage,
          previous_share: before && before.vote_percentage,
          swing: Results.swing(party.vote_percentage, (before && before.vote_percentage) || 0.0),
          new_party: is_nil(before),
          wards_gained: tally.(wards, :gained),
          wards_lost: tally.(wards, :lost),
          councils_gained: tally.(councils, :gained),
          councils_lost: tally.(councils, :lost)
        }
      end

    %{parties: parties, local_swings: local_swings(areas)}
  end

  # Per party: wards it took from another party, and wards another party took from it.
  # Like the party page, only a ward that existed before with the same shape counts; a
  # new or redrawn ward is neither gained nor lost. (Every ward at once, so the holders
  # are read in one query rather than through `ward_histories/2`.)
  defp ward_turnover do
    live_year = Results.live_year()
    previous_year = Results.previous_year()
    redrawn = Maps.list_redrawn_ward_ids()

    holders =
      Repo.all(
        from result in PartyWardResult,
          where: result.won,
          select: {{result.election, result.ward_id}, result.party_id}
      )
      |> Map.new()

    for {{^live_year, ward_id}, holder} <- holders,
        ward_id not in redrawn,
        previous_holder = holders[{previous_year, ward_id}],
        previous_holder not in [nil, holder],
        reduce: %{} do
      turnover ->
        turnover |> count_turnover(holder, :gained) |> count_turnover(previous_holder, :lost)
    end
  end

  # Per party: council majorities won and lost, counting complete councils only. A
  # majority lost to a hung council counts as lost with no one gaining it.
  defp council_turnover(areas) do
    control = get_council_control(Map.keys(areas))

    for {municipality_id, %{complete: true}} <- areas, reduce: %{} do
      turnover ->
        now = get_in(control, [{Results.live_year(), municipality_id}, :majority])
        before = get_in(control, [{Results.previous_year(), municipality_id}, :majority])

        if now == before,
          do: turnover,
          else: turnover |> count_turnover(now, :gained) |> count_turnover(before, :lost)
    end
  end

  defp count_turnover(turnover, nil, _key), do: turnover

  defp count_turnover(turnover, party_id, key),
    do: update_in(turnover, [Access.key(party_id, %{}), Access.key(key, 0)], &(&1 + 1))

  defp local_swings(areas) do
    swings =
      Repo.all(
        from now in PartyMunicipalityResult,
          join: before in PartyMunicipalityResult,
          on:
            before.party_id == now.party_id and before.municipality_id == now.municipality_id and
              before.election == ^Results.previous_year(),
          where:
            now.election == ^Results.live_year() and not is_nil(now.vote_percentage) and
              not is_nil(before.vote_percentage),
          select: %{
            party_id: now.party_id,
            municipality_id: now.municipality_id,
            share: now.vote_percentage,
            previous_share: before.vote_percentage,
            swing: now.vote_percentage - before.vote_percentage
          }
      )
      |> Enum.map(fn swing ->
        area = areas[swing.municipality_id] || %{name: "–", complete: false}

        %{swing | swing: Float.round(swing.swing, 2)}
        |> Map.merge(%{municipality_name: area.name, complete: area.complete})
      end)

    %{
      rises: swings |> Enum.sort_by(& &1.swing, :desc) |> Enum.take(10),
      falls: swings |> Enum.sort_by(& &1.swing) |> Enum.take(10)
    }
  end

  ## Council control

  @doc """
  Who controls each council, per election, among the parties we have files for:
  `%{{election, municipality_id} => %{majority: party_id | nil, largest: party_id | nil}}`.
  With no majority the council is hung (or still counting) and `largest` has the most seats.

  `get_council_control/2` returns one election's, keyed by municipality id.
  """
  def get_council_control(municipality_ids, year) do
    for {{^year, municipality_id}, control} <- get_council_control(municipality_ids),
        into: %{},
        do: {municipality_id, control}
  end

  def get_council_control(municipality_ids) do
    Repo.all(
      from result in PartyMunicipalityResult,
        where: result.municipality_id in ^municipality_ids,
        select: %{
          election: result.election,
          municipality_id: result.municipality_id,
          party_id: result.party_id,
          majority: result.majority,
          seats_won: result.seats_won
        }
    )
    |> Enum.group_by(&{&1.election, &1.municipality_id})
    |> Map.new(fn {key, results} ->
      majority = Enum.find(results, & &1.majority)
      largest = Enum.max_by(results, &(&1.seats_won || 0))

      {key,
       %{
         majority: majority && majority.party_id,
         largest: if((largest.seats_won || 0) > 0, do: largest.party_id)
       }}
    end)
  end

  ## Ward history

  # Each ward against the previous election, keyed by ward id:
  #
  #   * `holder`, `previous_holder` – its winner now and then (`party_id`,
  #     `vote_percentage`, `first_won_at`), nil when not declared or not known
  #   * `existed` – it had results then (some party's share)
  #   * `redrawn` – its outline changed clearly since then (`Iec.Maps`)
  #   * `abolished` – one of `abolished_ids` (gone from the live directory)
  #   * `comparable` – it had a winner then, kept its shape and still exists, so it can
  #     have changed hands; any other ward can only be won
  defp ward_histories(ward_ids, abolished_ids \\ MapSet.new()) do
    live_year = Results.live_year()
    previous_year = Results.previous_year()
    holders = ward_holders(ward_ids)
    redrawn_ids = Maps.list_redrawn_ward_ids()

    existed_ids =
      Repo.all(
        from result in PartyWardResult,
          where: result.election == ^previous_year and result.ward_id in ^ward_ids,
          distinct: true,
          select: result.ward_id
      )
      |> MapSet.new()

    Map.new(ward_ids, fn ward_id ->
      previous_holder = holders[{previous_year, ward_id}]
      redrawn = ward_id in redrawn_ids
      abolished = ward_id in abolished_ids

      {ward_id,
       %{
         holder: holders[{live_year, ward_id}],
         previous_holder: previous_holder,
         existed: ward_id in existed_ids,
         redrawn: redrawn,
         abolished: abolished,
         comparable: previous_holder != nil and not redrawn and not abolished
       }}
    end)
  end

  # Which party won each ward, per election, among the parties we have files for.
  defp ward_holders(ward_ids) do
    Repo.all(
      from result in PartyWardResult,
        where: result.won and result.ward_id in ^ward_ids,
        select: %{
          election: result.election,
          ward_id: result.ward_id,
          party_id: result.party_id,
          first_won_at: result.first_won_at,
          vote_percentage: result.vote_percentage
        }
    )
    |> Map.new(&{{&1.election, &1.ward_id}, &1})
  end

  # Who won a ward and when. A ward already declared when we first fetched the winner's
  # file has no real declaration time, only "before then".
  defp declaration(holder, first_fetched_at) do
    %{
      holder: holder && holder.party_id,
      declared_at: holder && holder.first_won_at,
      declared_before_tracking: declared_before_tracking?(holder, first_fetched_at)
    }
  end

  defp declared_before_tracking?(nil, _first_fetched_at), do: false

  defp declared_before_tracking?(holder, first_fetched_at) do
    case first_fetched_at[holder.party_id] do
      nil -> false
      fetched_at -> DateTime.diff(holder.first_won_at, fetched_at, :second) <= 5
    end
  end

  # When each party's live file was first stored, keyed by party id.
  # Shared through the cache: it scans the growing fetches table.
  defp first_party_fetches(year) do
    Iec.Cache.fetch({:first_party_fetches, year}, fn ->
      Repo.all(
        from fetch in Fetch,
          where: fetch.election == ^year and like(fetch.feed, "party-%"),
          group_by: fetch.feed,
          select: {fetch.feed, min(fetch.inserted_at)}
      )
      |> Map.new(fn {"party-" <> party_id, fetched_at} ->
        {String.to_integer(party_id), fetched_at}
      end)
    end)
  end

  defp swing(now, before),
    do: Results.swing(now && now.vote_percentage, before && before.vote_percentage)
end
