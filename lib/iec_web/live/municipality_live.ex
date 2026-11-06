defmodule IecWeb.MunicipalityLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents

  alias Iec.{Parties, Results}
  alias Iec.Results.Change
  alias IecWeb.TableRows

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(
       municipality_id: String.to_integer(id),
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    %{
      municipality_id: municipality_id,
      live_year: live_year,
      previous_year: previous_year,
      parties: parties
    } = socket.assigns

    municipality = Results.get_latest_snapshot(:municipality, municipality_id)
    overview = Parties.get_municipality_overview(municipality_id)
    control = Parties.get_council_control([municipality_id])

    previous_municipality =
      Results.get_latest_snapshot(:municipality, municipality_id, election: previous_year)

    # Every followed party from the party files; without them, the province feed's top three.
    party_rows =
      case overview.parties do
        [] -> TableRows.party_rows(municipality, previous_municipality, parties)
        rows -> TableRows.with_party_name(rows, parties, :party_id, :party)
      end

    ward_rows =
      overview.wards
      |> TableRows.with_party_name(parties, :holder, :holder_name)
      |> TableRows.with_party_name(parties, :previous_holder, :previous_holder_name)

    assign(socket,
      page_title: (municipality && municipality.area_name) || "Municipality",
      municipality: municipality,
      complete: municipality != nil and municipality.municipalities_complete == 1,
      province_name: municipality && Results.get_area_name(:province, municipality.province_id),
      previous_municipality: previous_municipality,
      from_party_files: overview.parties != [],
      party_rows: party_rows,
      ward_rows: ward_rows,
      wards_declared: Enum.count(ward_rows, & &1.holder),
      wards_changed: Enum.count(ward_rows, & &1.changed_hands),
      control: control[{live_year, municipality_id}],
      previous_control: control[{previous_year, municipality_id}],
      changes:
        Results.list_changes(level: :municipality, area_id: municipality_id, changed_only: true)
        |> Enum.map(&Change.compare/1)
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <div :if={is_nil(@municipality)} class="alert">No results for this municipality yet.</div>

      <div :if={@municipality} class="space-y-8">
        <div>
          <div class="text-sm">
            <.link navigate={~p"/"} class="link">National</.link>
            /
            <.link navigate={~p"/provinces/#{@municipality.province_id}"} class="link">
              {@province_name}
            </.link>
          </div>
          <h1 class="text-2xl font-semibold">{@municipality.area_name}</h1>
        </div>

        <div class="grid gap-4 sm:grid-cols-3">
          <.progress
            label="Voting districts"
            complete={@municipality.voting_districts_complete}
            expected={@municipality.voting_districts_expected}
          />
          <.progress
            label="Wards"
            complete={@municipality.wards_complete}
            expected={@municipality.wards_expected}
          />
          <.progress
            label="Seats"
            complete={@municipality.seats_complete}
            expected={@municipality.seats_expected}
          />
        </div>

        <dl class="grid grid-cols-2 gap-4 text-sm">
          <div>
            <dt class="opacity-60">Council {if @complete, do: "", else: "(counting)"}</dt>
            <dd class="mt-1">
              <.council_control parties={@parties} control={@control} counting={not @complete} />
            </dd>
          </div>
          <div>
            <dt class="opacity-60">Council in {@previous_year}</dt>
            <dd class="mt-1"><.council_control parties={@parties} control={@previous_control} /></dd>
          </div>
        </dl>

        <.turnout
          snapshot={@municipality}
          previous_election={@previous_municipality}
          previous_year={@previous_year}
          show_councils={false}
        />

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Parties</h2>
          <.party_table
            :if={not @from_party_files}
            id="municipality-parties"
            rows={@party_rows}
            parties={@parties}
            previous_year={@previous_year}
            sorts={@sorts}
          />
          <.council_party_table
            :if={@from_party_files}
            id="municipality-parties"
            rows={@party_rows}
            parties={@parties}
            previous_year={@previous_year}
            sorts={@sorts}
          />
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Wards map</h2>
          <.live_component
            module={IecWeb.MapComponent}
            id="municipality-map"
            level={:ward}
            municipality_id={@municipality_id}
            parties={@parties}
            refreshed_at={@refreshed_at}
          />
        </section>

        <section :if={@ward_rows != []} class="space-y-2">
          <h2 class="text-lg font-semibold">
            Wards
            <span class="badge badge-sm">{@wards_declared} / {length(@ward_rows)} declared</span>
            <span class="badge badge-warning badge-sm">{@wards_changed} changed hands</span>
          </h2>
          <.ward_winners_table
            id="municipality-wards"
            rows={@ward_rows}
            parties={@parties}
            previous_year={@previous_year}
            sorts={@sorts}
          />
        </section>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">History</h2>
          <p :if={@changes == []} class="text-sm opacity-60">Nothing has moved since start-up.</p>
          <ul id="municipality-changes" class="divide-y divide-base-300">
            <.change_entry
              :for={change <- @changes}
              change={change}
              parties={@parties}
              show_area={false}
            />
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  # Every followed party's share and seats in this council, from the party files.
  defp council_party_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <.sort_header table={@id} column="party" sorts={@sorts} first="asc">Party</.sort_header>
            <.sort_header table={@id} column="share" sorts={@sorts} align="right">Share</.sort_header>
            <.sort_header table={@id} column="previous_share" sorts={@sorts} align="right">
              {@previous_year}
            </.sort_header>
            <.sort_header table={@id} column="swing" sorts={@sorts} align="right">Swing</.sort_header>
            <.sort_header table={@id} column="seats" sorts={@sorts} align="right">Seats</.sort_header>
            <.sort_header table={@id} column="previous_seats" sorts={@sorts} align="right">
              {@previous_year}
            </.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- sort_rows(@rows, @sorts[@id])} id={"#{@id}-#{row.party_id}"}>
            <td>
              <.party_label parties={@parties} party_result={row} />
              <span :if={row.majority} class="badge badge-success badge-sm ml-2">majority</span>
            </td>
            <td class="text-right tabular-nums">{format_percentage(row.share)}</td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(row.previous_share)}
            </td>
            <td class={["text-right tabular-nums", delta_class(row.swing)]}>
              {format_delta(row.swing, :points)}
            </td>
            <td class="text-right tabular-nums">{format_number(row.seats)}</td>
            <td class="text-right tabular-nums opacity-60">{format_number(row.previous_seats)}</td>
          </tr>
        </tbody>
      </table>
      <p class="mt-2 text-sm opacity-60">
        Parties the app follows (the national list, plus any whose page you opened).
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  # Each ward's winner now and in the previous election.
  defp ward_winners_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <.sort_header table={@id} column="ward_number" sorts={@sorts} first="asc">
              Ward
            </.sort_header>
            <.sort_header table={@id} column="holder_name" sorts={@sorts} first="asc">
              Winner
            </.sort_header>
            <.sort_header table={@id} column="share" sorts={@sorts} align="right">Share</.sort_header>
            <.sort_header table={@id} column="previous_holder_name" sorts={@sorts} first="asc">
              {@previous_year}
            </.sort_header>
            <.sort_header table={@id} column="previous_share" sorts={@sorts} align="right">
              {@previous_year} share
            </.sort_header>
            <.sort_header table={@id} column="declared_at" sorts={@sorts}>Declared</.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={ward <- sort_rows(@rows, @sorts[@id])}
            id={"ward-#{ward.ward_id}"}
            class={ward.changed_hands && "bg-warning/10"}
          >
            <td class="tabular-nums">
              {ward.ward_number}
              <span :if={ward.new_ward} class="badge badge-ghost badge-sm">new</span>
              <span
                :if={ward.redrawn}
                class="badge badge-ghost badge-sm"
                title="Boundary changed since the previous election"
              >
                redrawn
              </span>
            </td>
            <td>
              <.party_or_dash parties={@parties} party_id={ward.holder} empty="not declared" />
            </td>
            <td class="text-right tabular-nums">{format_percentage(ward.share)}</td>
            <td class="opacity-75">
              <.party_or_dash parties={@parties} party_id={ward.previous_holder} />
            </td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(ward.previous_share)}
            </td>
            <td class="tabular-nums opacity-75"><.declared_at ward={ward} /></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
