defmodule IecWeb.AboutLive do
  use IecWeb, :live_view

  import IecWeb.DesignComponents

  alias Iec.Results

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results]}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "About",
       live_year: Results.live_year(),
       previous_year: Results.previous_year(),
       first_year: Iec.Results.Feed.all_elections() |> hd() |> Map.fetch!(:year)
     )}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket), do: socket

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      feed_status={@feed_status}
      count_progress={@count_progress}
      active={:about}
    >
      <.page_header eyebrow="About" title="An independent results desk">
        <:lede>
          A live, unofficial view of South Africa's {@live_year} Local Government Elections,
          built on the Electoral Commission's public results, with a history of every change
          and comparisons back to {@first_year}.
        </:lede>
      </.page_header>

      <div class="grid gap-6 lg:grid-cols-3">
        <div class="space-y-10 lg:col-span-2">
          <.about_section title="Not an official source">
            <p>
              This site is independent. It is not affiliated with, endorsed by or operated on
              behalf of the Electoral Commission of South Africa (IEC), any party or any
              government body.
            </p>
            <p>
              The <strong>official results</strong>
              are those declared by the IEC, published at
              <a href="https://results.elections.org.za" class="link" rel="noopener">
                results.elections.org.za
              </a>
              and <a href="https://www.elections.org.za" class="link" rel="noopener">elections.org.za</a>.
              Figures here can lag the IEC, may be incomplete while counting runs, and can be
              wrong. Do not rely on them for any official, legal or financial purpose.
            </p>
          </.about_section>

          <.about_section title="Where the data comes from">
            <ul class="list-disc space-y-2 pl-5">
              <li>
                <strong>Results</strong>: the IEC's public results dashboard files (national,
                provincial, municipal, party and ward results) for {@live_year} and the earlier
                local elections.
              </li>
              <li>
                <strong>Party names and colours</strong>: the IEC dashboard's party lists.
              </li>
              <li>
                <strong>Map outlines</strong>: the IEC's election map, based on Municipal
                Demarcation Board boundaries; simplified for display.
              </li>
              <li>
                <strong>Town and suburb names</strong>, for finding a ward:
                <a href="https://www.openstreetmap.org/copyright" class="link" rel="noopener">
                  OpenStreetMap
                </a>
                (cities, towns, villages, suburbs and neighbourhoods), read once through the
                Overpass API. Each name is a single point, placed in the ward whose outline holds
                it; a suburb can reach into neighbouring wards, so treat it as a pointer, not a
                boundary. Street addresses are not looked up.
              </li>
            </ul>
            <p>
              Results data © Electoral Commission of South Africa. Boundaries © Municipal
              Demarcation Board and the IEC.
              Town and suburb names © <a
                href="https://www.openstreetmap.org/copyright"
                class="link"
                rel="noopener"
              >
                OpenStreetMap contributors
              </a>, available under the Open Database Licence.
            </p>
          </.about_section>

          <.about_section title="Asking politely">
            <p>
              Everything is fetched by the server in the background, never while you browse,
              and every request names this site so its owners can see who is asking.
            </p>
            <ul class="list-disc space-y-2 pl-5">
              <li>
                <strong>The IEC</strong>: each file is asked for again only when the IEC's own
                cache says it may have changed, with conditional requests, so an unchanged file
                costs almost nothing. Polling backs off when a file fails.
              </li>
              <li>
                <strong>OpenStreetMap</strong>: four queries to the Overpass API, once, one at a
                time, each only when Overpass reports a free slot for us, waiting longer and
                longer when it is busy, and trying again half an hour later rather than pressing it;
                well inside its <a
                  href="https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances"
                  class="link"
                  rel="noopener"
                >
                  usage policy
                </a>. Searching never calls it.
              </li>
            </ul>
          </.about_section>

          <.about_section title="How it works">
            <p>
              The site reads the same files the IEC's public dashboard reads. While counting
              runs it asks for each file again when the cached copy expires, about once a
              minute for national and provincial results and every few minutes for smaller
              parties, and only stores what changed. Every page updates by itself; the footer
              shows when the feed was last checked and the time of the IEC's latest report.
            </p>
            <p>
              Each change is kept with the time it was seen, which is what the Changes page and
              the "declared" times show. Times are South African Standard Time.
            </p>
          </.about_section>

          <.about_section title="How to read it">
            <ul class="list-disc space-y-2 pl-5">
              <li>
                <strong>Vote share</strong> is the IEC's share of valid votes (ward and
                proportional ballots together). <strong>Swing</strong> is the change in
                percentage points since {@previous_year}.
              </li>
              <li>
                <strong>Leading</strong>
                means most votes so far; a council is <strong>hung</strong>
                when its count is complete and no party holds over half
                its seats.
              </li>
              <li>
                Wards are compared with {@previous_year} only where the ward kept its shape.
                Wards that are new or were <strong>redrawn</strong> since then (judged from the
                map outlines) are shown as won, not as gained or lost.
              </li>
              <li>
                Before a ward is declared, its leader is worked out from the parties' running
                shares; the declared winner replaces it once the IEC declares.
              </li>
              <li>
                Ballots cast count every ballot, and each voter casts more than one, so ballots
                run ahead of voters. Older elections had different municipal boundaries, so
                trends are shown nationally and by province.
              </li>
              <li>
                The written summaries at the top of pages are generated from the figures and
                follow them as they change.
              </li>
            </ul>
          </.about_section>
        </div>

        <aside class="space-y-4">
          <div class="panel space-y-3 p-5 text-sm">
            <div class="eyebrow">Official results</div>
            <a
              href="https://results.elections.org.za"
              rel="noopener"
              class="flex items-center justify-between gap-2 font-medium hover:underline"
            >
              IEC results dashboard
              <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
            </a>
            <a
              href="https://www.elections.org.za"
              rel="noopener"
              class="flex items-center justify-between gap-2 font-medium hover:underline"
            >
              Electoral Commission
              <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
            </a>
          </div>
          <div class="panel space-y-3 p-5 text-sm">
            <div class="eyebrow">Open source</div>
            <p class="text-base-content/70">
              The code is public under the MIT licence. Corrections and ideas are welcome.
            </p>
            <a
              href="https://github.com/wkirschbaum/iec"
              rel="noopener"
              class="flex items-center justify-between gap-2 font-medium hover:underline"
            >
              github.com/wkirschbaum/iec
              <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
            </a>
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp about_section(assigns) do
    ~H"""
    <section class="space-y-3">
      <.section_heading title={@title} />
      <div class="max-w-prose space-y-3 leading-relaxed text-base-content/80">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end
end
