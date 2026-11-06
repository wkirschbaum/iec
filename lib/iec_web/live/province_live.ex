defmodule IecWeb.ProvinceLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.{Parties, Results}
  alias Iec.Results.Change
  alias IecWeb.{ChangeDigest, Narrative, TableRows}

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(
       province_id: IecWeb.Params.id(id),
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    assign(socket, Iec.Cache.fetch(cache_key(socket.assigns), fn -> load(socket.assigns) end))
  end

  # Computed once per data change and shared by everyone viewing the same page.
  defp cache_key(assigns), do: {__MODULE__, assigns.province_id}

  defp load(%{province_id: nil}), do: %{page_title: "Province", province: nil}

  defp load(assigns) do
    %{
      province_id: province_id,
      live_year: live_year,
      previous_year: previous_year,
      parties: parties
    } = assigns

    province = Results.get_latest_snapshot(:province, province_id)
    municipalities = Results.list_latest_snapshots(level: :municipality, province_id: province_id)

    previous_municipalities =
      Results.list_latest_snapshots(
        election: previous_year,
        level: :municipality,
        province_id: province_id
      )
      |> Map.new(&{&1.area_id, &1})

    control = Parties.get_council_control(Enum.map(municipalities, & &1.area_id), live_year)

    previous_province =
      Results.get_latest_snapshot(:province, province_id, election: previous_year)

    party_rows = TableRows.party_rows(province, previous_province, parties)

    Map.new(
      page_title: (province && province.area_name) || "Province",
      province: province,
      previous_province: previous_province,
      party_rows: party_rows,
      municipality_rows:
        TableRows.area_rows(municipalities, previous_municipalities, parties, control),
      summary: Narrative.summary(province, party_rows, parties, previous_year),
      highlights:
        Results.list_changes(province_id: province_id, changed_only: true, limit: 200)
        |> Enum.map(&Change.compare/1)
        |> ChangeDigest.highlights()
        |> Enum.take(8)
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.page_header :if={is_nil(@province)} eyebrow="Province" title="No results">
        <:breadcrumb><.link navigate={~p"/"} class="link-hover link">Overview</.link> /</:breadcrumb>
        <:lede>No results for this province yet, or no province has this id.</:lede>
      </.page_header>

      <.page_header
        :if={@province}
        eyebrow={@summary && @summary.eyebrow}
        live={@summary != nil and @summary.live}
        title={@province.area_name}
      >
        <:breadcrumb><.link navigate={~p"/"} class="link-hover link">Overview</.link> /</:breadcrumb>
        <:lede :if={@summary}>{@summary.headline}. {@summary.lede}</:lede>
      </.page_header>

      <section :if={@province} class="panel space-y-8 p-5 sm:p-7">
        <.vote_share_bar rows={@party_rows} parties={@parties} previous_year={@previous_year} />
        <div class="grid grid-cols-2 gap-6 border-t border-base-300 pt-6 lg:grid-cols-4">
          <.kpi
            label="Districts counted"
            value={
              format_progress(
                @province.voting_districts_complete,
                @province.voting_districts_expected
              )
            }
          >
            {format_number(@province.voting_districts_complete)} of {format_number(
              @province.voting_districts_expected
            )}
          </.kpi>
          <.kpi label="Votes counted" value={format_compact(@province.total_votes_cast)}>
            {format_compact(@previous_province && @previous_province.total_votes_cast)} in all of {@previous_year}
          </.kpi>
          <.kpi
            label="Councils decided"
            value={"#{@province.municipalities_complete} / #{@province.municipalities_expected}"}
          >
            {@province.majority_councils} with a majority
          </.kpi>
          <.kpi label="Hung councils" value={format_number(@province.hung_councils)}>
            no party over half the seats
          </.kpi>
        </div>
      </section>

      <section :if={@province} class="space-y-4">
        <.section_heading title="Who leads where">
          <:subtitle>Each municipality in its leading party's colour</:subtitle>
          <:actions>
            <.link
              navigate={~p"/map?#{[level: "wards", province: @province_id]}"}
              class="link-hover link"
            >
              Ward map →
            </.link>
          </:actions>
        </.section_heading>
        <.live_component
          module={IecWeb.MapComponent}
          id="province-map"
          level={:municipality}
          province_id={@province_id}
          parties={@parties}
          refreshed_at={@refreshed_at}
        />
      </section>

      <section :if={@province} class="space-y-4">
        <.section_heading title="Municipalities">
          <:subtitle>Who runs each council, who leads, and who led in {@previous_year}</:subtitle>
        </.section_heading>
        <div class="panel p-2 sm:p-4">
          <.area_table
            id="municipalities"
            rows={@municipality_rows}
            parties={@parties}
            previous_year={@previous_year}
            sorts={@sorts}
            area_label="Municipality"
            area_path={&~p"/municipalities/#{&1}"}
            show_council
          />
        </div>
      </section>

      <section :if={@province} class="space-y-4">
        <.section_heading title="Highlights">
          <:subtitle>Leads changing hands and councils decided in {@province.area_name}</:subtitle>
        </.section_heading>
        <p :if={@highlights == []} class="text-sm text-base-content/60">
          No lead has changed hands here since start-up.
        </p>
        <ul :if={@highlights != []} class="panel divide-y divide-base-300">
          <.highlight :for={event <- @highlights} event={event} parties={@parties} />
        </ul>
      </section>

      <section :if={@province} class="space-y-4">
        <.section_heading title="All parties" />
        <div class="panel p-2 sm:p-4">
          <.party_table
            id="province-parties"
            rows={@party_rows}
            parties={@parties}
            previous_year={@previous_year}
            sorts={@sorts}
            show_councils
          />
        </div>
      </section>
    </Layouts.app>
    """
  end
end
