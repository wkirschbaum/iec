defmodule IecWeb.ProvinceLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.{Parties, Results}
  alias Iec.Results.Change
  alias IecWeb.{ChangeDigest, LiveUpdates, Narrative, TableRows}

  @behaviour LiveUpdates
  on_mount {LiveUpdates, [:results, :parties]}

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

  @impl LiveUpdates
  def refresh(socket),
    do: LiveUpdates.assign_cached(socket, {__MODULE__, socket.assigns.province_id}, &load/1)

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

    %{
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
    }
  end

  @impl Phoenix.LiveView
  def render(%{province: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.not_found eyebrow="Province" title="No results">
        No results for this province yet, or no province has this id.
      </.not_found>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.page_header
        eyebrow={@summary && @summary.eyebrow}
        live={@summary != nil and @summary.live}
        title={@province.area_name}
        crumbs={[{"Overview", ~p"/"}]}
      >
        <:lede :if={@summary}>{@summary.headline}. {@summary.lede}</:lede>
      </.page_header>

      <section class="panel space-y-8 p-5 sm:p-7">
        <.vote_share_bar rows={@party_rows} parties={@parties} previous_year={@previous_year} />
        <div class="grid grid-cols-2 gap-6 border-t border-base-300 pt-6 lg:grid-cols-4">
          <.count_kpis snapshot={@province}>
            <:votes_note>
              {format_compact(@previous_province && @previous_province.total_votes_cast)} in all of {@previous_year}
            </:votes_note>
          </.count_kpis>
        </div>
      </section>

      <section class="space-y-4">
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

      <section class="space-y-4">
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

      <.highlights highlights={@highlights} parties={@parties} area={@province.area_name} />

      <section class="space-y-4">
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
