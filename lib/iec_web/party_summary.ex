defmodule IecWeb.PartySummary do
  @moduledoc """
  Turns `Iec.Parties.get_party_overview/1` into what the party page shows: headline
  stats, who the party lost to and gained from, net change per province, and the rows of
  each council and ward section, ready to sort.
  """

  import IecWeb.ResultsComponents, only: [party_abbreviation: 2]

  alias Iec.Results
  alias IecWeb.TableRows

  @doc """
  Council and ward sections of the party page. Each lists the councils or wards with one
  status; `other` heads a column naming who it went to or came from (`other_field` of
  the row), if anyone.
  """
  def sections(live_year, previous_year) do
    %{
      councils: [
        %{
          id: "municipalities-gained",
          title: "Majority gained",
          status: :gained,
          other: "Taken from",
          other_field: :previous_control,
          counting: false
        },
        %{
          id: "municipalities-lost-to-party",
          title: "Majority lost to another party",
          status: :lost_to_party,
          other: "Now held by",
          other_field: :control,
          counting: false
        },
        %{
          id: "municipalities-lost-hung",
          title: "Majority lost to a hung council",
          status: :lost_hung,
          other: "Now",
          other_field: :control,
          counting: false
        },
        %{
          id: "municipalities-pending",
          title: "Held in #{previous_year} · #{live_year} count in progress",
          status: :pending,
          other: "Leading now",
          other_field: :control,
          counting: true
        },
        %{
          id: "municipalities-kept",
          title: "Majority kept",
          status: :kept,
          other: nil,
          other_field: nil,
          counting: false
        }
      ],
      wards: [
        %{
          id: "wards-gained",
          title: "Gained",
          status: :gained,
          other: "Taken from",
          other_field: :previous_holder
        },
        %{id: "wards-lost", title: "Lost", status: :lost, other: "Lost to", other_field: :holder},
        %{
          id: "wards-pending",
          title: "Held in #{previous_year} · #{live_year} result not declared yet",
          status: :pending,
          other: nil,
          other_field: nil
        },
        %{id: "wards-held", title: "Held", status: :held, other: nil, other_field: nil}
      ]
    }
  end

  @doc "Everything the party page renders, from the party's overview."
  def build(overview, parties, province_names, sections) do
    councils = Enum.group_by(overview.municipalities, & &1.status)
    wards = Enum.group_by(overview.wards, & &1.status)

    count = fn groups, statuses ->
      statuses |> Enum.map(&length(Map.get(groups, &1, []))) |> Enum.sum()
    end

    %{
      stats: stats(overview, councils, wards, count),
      breakdowns: %{
        wards_lost_to: breakdown(wards[:lost] || [], :holder),
        wards_gained_from:
          breakdown(Enum.reject(wards[:gained] || [], & &1.new_ward), :previous_holder),
        new_wards: Enum.count(wards[:gained] || [], & &1.new_ward),
        councils_lost_to:
          council_breakdown(
            (councils[:lost_to_party] || []) ++ (councils[:lost_hung] || []),
            :control
          ),
        councils_gained_from: council_breakdown(councils[:gained] || [], :previous_control)
      },
      provinces: province_rows(councils, wards, province_names),
      section_rows:
        Map.merge(
          Map.new(
            sections.councils,
            &{&1.id, council_rows(councils[&1.status] || [], &1, parties)}
          ),
          Map.new(sections.wards, &{&1.id, ward_rows(wards[&1.status] || [], &1, parties)})
        )
    }
  end

  defp stats(overview, councils, wards, count) do
    national = overview.national || %{}
    previous = overview.previous_national || %{}
    share = Map.get(national, :vote_percentage)
    previous_share = Map.get(previous, :vote_percentage)

    %{
      votes: Map.get(national, :total_valid_votes),
      previous_votes: Map.get(previous, :total_valid_votes),
      share: share,
      previous_share: previous_share,
      swing: Results.swing(share, previous_share),
      seats: Map.get(national, :total_seats_won),
      previous_seats: Map.get(previous, :total_seats_won),
      ward_seats: Map.get(national, :ward_seats_won),
      previous_ward_seats: Map.get(previous, :ward_seats_won),
      majorities: Map.get(national, :majority_won),
      previous_majorities: Map.get(previous, :majority_won),
      councils_gained: count.(councils, [:gained]),
      councils_lost: count.(councils, [:lost_to_party, :lost_hung]),
      councils_kept: count.(councils, [:kept]),
      councils_pending: count.(councils, [:pending]),
      wards_gained: count.(wards, [:gained]),
      wards_lost: count.(wards, [:lost]),
      wards_held: count.(wards, [:held]),
      wards_pending: count.(wards, [:pending]),
      wards_contested: length(overview.wards),
      municipalities_contested: length(overview.municipalities)
    }
  end

  # How many wards went to (or came from) each party, most first; nil is a party without
  # a stored file.
  defp breakdown(rows, party_field) do
    rows
    |> Enum.frequencies_by(&Map.get(&1, party_field))
    |> Enum.sort_by(fn {_party_id, count} -> -count end)
  end

  defp council_breakdown(rows, control_field) do
    rows
    |> Enum.frequencies_by(fn row ->
      case Map.get(row, control_field) do
        %{majority: party_id} when not is_nil(party_id) -> party_id
        _hung_or_unknown -> :hung
      end
    end)
    |> Enum.sort_by(fn {_key, count} -> -count end)
  end

  # Gains and losses per province, biggest net loss first.
  defp province_rows(councils, wards, province_names) do
    count_by_province = fn groups, statuses ->
      groups
      |> Map.take(statuses)
      |> Map.values()
      |> List.flatten()
      |> Enum.frequencies_by(& &1.province_id)
    end

    wards_gained = count_by_province.(wards, [:gained])
    wards_lost = count_by_province.(wards, [:lost])
    councils_gained = count_by_province.(councils, [:gained])
    councils_lost = count_by_province.(councils, [:lost_to_party, :lost_hung])

    [wards_gained, wards_lost, councils_gained, councils_lost]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.map(fn province_id ->
      gained = Map.get(wards_gained, province_id, 0)
      lost = Map.get(wards_lost, province_id, 0)

      %{
        province_id: province_id,
        name: province_names[province_id] || "Unknown",
        wards_gained: gained,
        wards_lost: lost,
        net: gained - lost,
        councils_gained: Map.get(councils_gained, province_id, 0),
        councils_lost: Map.get(councils_lost, province_id, 0)
      }
    end)
    |> Enum.sort_by(&{&1.net, &1.name})
  end

  # `other` is who runs the council now or before (per the section), `other_label` the
  # same as sortable text.
  defp council_rows(rows, section, parties) do
    Enum.map(rows, fn row ->
      other = section.other_field && Map.get(row, section.other_field)

      Map.merge(row, %{
        other: other,
        other_label: TableRows.council_label(other, parties, section.counting)
      })
    end)
  end

  # Wards sort by municipality then ward number; `other` is the party the ward went to or
  # came from (per the section), `other_label` its name.
  defp ward_rows(rows, section, parties) do
    Enum.map(rows, fn row ->
      other = section.other_field && Map.get(row, section.other_field)

      Map.merge(row, %{
        ward: {row.municipality_name, row.ward_number},
        other: other,
        other_label: other && party_abbreviation(parties, %{party_id: other})
      })
    end)
  end
end
