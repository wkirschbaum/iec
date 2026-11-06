defmodule IecWeb.MunicipalityLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents

  alias Iec.{Parties, Results}
  alias Iec.Results.Change

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
    %{municipality_id: municipality_id, live_year: live_year, previous_year: previous_year} =
      socket.assigns

    municipality = Results.get_latest_snapshot(:municipality, municipality_id)
    overview = Parties.get_municipality_overview(municipality_id)
    control = Parties.get_council_control([municipality_id])

    assign(socket,
      page_title: (municipality && municipality.area_name) || "Municipality",
      municipality: municipality,
      province_name: municipality && Results.get_area_name(:province, municipality.province_id),
      previous_municipality:
        Results.get_latest_snapshot(:municipality, municipality_id, election: previous_year),
      parties_overview: overview.parties,
      wards: overview.wards,
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
          <p class="text-sm opacity-60">
            IEC report {format_time(@municipality.report_date)} SAST
          </p>
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
            <dt class="opacity-60">
              Council {if @municipality.municipalities_complete == 1, do: "", else: "(counting)"}
            </dt>
            <dd class="mt-1">
              <.council_control
                parties={@parties}
                control={@control}
                counting={@municipality.municipalities_complete != 1}
              />
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
            :if={@parties_overview == []}
            id="municipality-parties"
            parties={@parties}
            snapshot={@municipality}
            previous_election={@previous_municipality}
            previous_year={@previous_year}
          />
          <div :if={@parties_overview != []} class="overflow-x-auto">
            <table id="municipality-parties" class="table table-sm">
              <thead>
                <tr>
                  <th>Party</th>
                  <th class="text-right">Share</th>
                  <th class="text-right">{@previous_year}</th>
                  <th class="text-right">Swing</th>
                  <th class="text-right">Seats</th>
                  <th class="text-right">{@previous_year}</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={party <- @parties_overview}
                  id={"municipality-party-#{party.party_id}"}
                >
                  <td>
                    <.party_label parties={@parties} party_result={party} />
                    <span :if={party.majority} class="badge badge-success badge-sm ml-2">
                      majority
                    </span>
                  </td>
                  <td class="text-right tabular-nums">{format_percentage(party.share)}</td>
                  <td class="text-right tabular-nums opacity-60">
                    {format_percentage(party.previous_share)}
                  </td>
                  <td class={["text-right tabular-nums", delta_class(party.swing)]}>
                    {format_delta(party.swing, :points)}
                  </td>
                  <td class="text-right tabular-nums">{format_number(party.seats)}</td>
                  <td class="text-right tabular-nums opacity-60">
                    {format_number(party.previous_seats)}
                  </td>
                </tr>
              </tbody>
            </table>
            <p class="text-sm opacity-60 mt-2">
              Parties the app follows (the national list, plus any whose page you opened).
            </p>
          </div>
        </section>

        <section :if={@wards != []} class="space-y-2">
          <h2 class="text-lg font-semibold">
            Wards
            <span class="badge badge-sm">
              {Enum.count(@wards, & &1.holder)} / {length(@wards)} declared
            </span>
            <span class="badge badge-warning badge-sm">
              {Enum.count(@wards, & &1.changed_hands)} changed hands
            </span>
          </h2>
          <div class="overflow-x-auto">
            <table id="municipality-wards" class="table table-sm">
              <thead>
                <tr>
                  <th>Ward</th>
                  <th>Winner</th>
                  <th class="text-right">Share</th>
                  <th>{@previous_year}</th>
                  <th class="text-right">{@previous_year} share</th>
                  <th>Declared</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={ward <- @wards}
                  id={"ward-#{ward.ward_id}"}
                  class={ward.changed_hands && "bg-warning/10"}
                >
                  <td class="tabular-nums">
                    {ward.ward_number}
                    <span :if={ward.new_ward} class="badge badge-ghost badge-sm">new</span>
                  </td>
                  <td>
                    <.party_label
                      :if={ward.holder}
                      parties={@parties}
                      party_result={%{party_id: ward.holder}}
                    />
                    <span :if={is_nil(ward.holder)} class="opacity-60">not declared</span>
                  </td>
                  <td class="text-right tabular-nums">{format_percentage(ward.share)}</td>
                  <td class="opacity-75">
                    <.party_label
                      :if={ward.previous_holder}
                      parties={@parties}
                      party_result={%{party_id: ward.previous_holder}}
                    />
                  </td>
                  <td class="text-right tabular-nums opacity-60">
                    {format_percentage(ward.previous_share)}
                  </td>
                  <td class="tabular-nums opacity-75">
                    <.declared_at ward={ward} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
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
end
