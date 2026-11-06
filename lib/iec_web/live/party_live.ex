defmodule IecWeb.PartyLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents

  alias Iec.{Parties, Results}

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    party_id = String.to_integer(id)
    if connected?(socket), do: Parties.track_party(party_id)

    {:ok,
     socket
     |> assign(
       party_id: party_id,
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    overview = Parties.get_party_overview(socket.assigns.party_id)
    municipalities = Enum.group_by(overview.municipalities, & &1.status)
    wards = Enum.group_by(overview.wards, & &1.status)

    assign(socket,
      page_title:
        party_abbreviation(socket.assigns.parties, %{party_id: socket.assigns.party_id}),
      overview: overview,
      municipalities: municipalities,
      wards: wards,
      provinces: province_summary(municipalities, wards, Results.list_area_names(:province))
    )
  end

  ## Aggregation

  # Gains and losses per province, biggest net change first.
  defp province_summary(municipalities, wards, province_names) do
    count_by_province = fn groups, statuses ->
      groups
      |> Map.take(statuses)
      |> Map.values()
      |> List.flatten()
      |> Enum.frequencies_by(& &1.province_id)
    end

    wards_gained = count_by_province.(wards, [:gained])
    wards_lost = count_by_province.(wards, [:lost])
    councils_gained = count_by_province.(municipalities, [:gained])
    councils_lost = count_by_province.(municipalities, [:lost_to_party, :lost_hung])

    [wards_gained, wards_lost, councils_gained, councils_lost]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.map(fn province_id ->
      %{
        province_id: province_id,
        name: province_names[province_id] || "Unknown",
        wards_gained: Map.get(wards_gained, province_id, 0),
        wards_lost: Map.get(wards_lost, province_id, 0),
        councils_gained: Map.get(councils_gained, province_id, 0),
        councils_lost: Map.get(councils_lost, province_id, 0)
      }
    end)
    |> Enum.sort_by(&{&1.wards_gained - &1.wards_lost, &1.name})
  end

  # How many rows went to (or came from) each party, most first. `nil` is a party we
  # have no file for.
  defp breakdown(rows, party_key) do
    rows
    |> Enum.frequencies_by(&Map.get(&1, party_key))
    |> Enum.sort_by(fn {_party_id, count} -> -count end)
  end

  defp council_breakdown(rows, control_key) do
    rows
    |> Enum.frequencies_by(fn row ->
      case Map.get(row, control_key) do
        %{majority: party_id} when not is_nil(party_id) -> party_id
        _hung_or_unknown -> :hung
      end
    end)
    |> Enum.sort_by(fn {_key, count} -> -count end)
  end

  defp count(groups, statuses) do
    statuses |> List.wrap() |> Enum.map(&length(Map.get(groups, &1, []))) |> Enum.sum()
  end

  defp share_swing(%{vote_percentage: now}, %{vote_percentage: before}),
    do: Float.round(now - before, 2)

  defp share_swing(_national, _previous), do: nil

  ## Rendering

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold flex items-center gap-3">
            <span
              class="inline-block size-4 rounded-full"
              style={"background-color: #{party_colour(@parties, %{party_id: @party_id})}"}
            />
            {party_abbreviation(@parties, %{party_id: @party_id})}
          </h1>
          <p :if={@parties[@party_id]} class="opacity-75">{@parties[@party_id].name}</p>
        </div>
        <p class="text-sm opacity-60 text-right">
          Party file updated {format_time(@overview.updated_at)} SAST<br />
          compared with {@previous_year}
        </p>
      </div>

      <.stats
        overview={@overview}
        municipalities={@municipalities}
        wards={@wards}
        previous_year={@previous_year}
      />

      <section id="at-a-glance" class="space-y-4">
        <h2 class="text-xl font-semibold">At a glance</h2>
        <div class="grid gap-4 lg:grid-cols-2">
          <.breakdown_card
            id="wards-lost-to"
            title="Wards lost to"
            total={count(@wards, :lost)}
            items={breakdown(@wards[:lost] || [], :holder)}
            parties={@parties}
          />
          <.breakdown_card
            id="wards-gained-from"
            title="Wards gained from"
            total={count(@wards, :gained)}
            items={breakdown(Enum.reject(@wards[:gained] || [], & &1.new_ward), :previous_holder)}
            parties={@parties}
            footnote={"plus #{Enum.count(@wards[:gained] || [], & &1.new_ward)} new wards"}
          />
          <.breakdown_card
            id="councils-lost-to"
            title="Council majorities lost to"
            total={count(@municipalities, [:lost_to_party, :lost_hung])}
            items={
              council_breakdown(
                (@municipalities[:lost_to_party] || []) ++ (@municipalities[:lost_hung] || []),
                :control
              )
            }
            parties={@parties}
          />
          <.breakdown_card
            id="councils-gained-from"
            title="Council majorities gained from"
            total={count(@municipalities, :gained)}
            items={council_breakdown(@municipalities[:gained] || [], :previous_control)}
            parties={@parties}
          />
        </div>

        <div :if={@provinces != []} class="overflow-x-auto">
          <table id="province-summary" class="table table-sm">
            <thead>
              <tr>
                <th>Province</th>
                <th class="text-right">Wards gained</th>
                <th class="text-right">Wards lost</th>
                <th class="text-right">Net</th>
                <th class="text-right">Councils gained</th>
                <th class="text-right">Councils lost</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={province <- @provinces} id={"province-summary-#{province.province_id}"}>
                <td>
                  <.link
                    :if={province.province_id}
                    navigate={~p"/provinces/#{province.province_id}"}
                    class="link"
                  >
                    {province.name}
                  </.link>
                  <span :if={is_nil(province.province_id)}>{province.name}</span>
                </td>
                <td class="text-right tabular-nums">{province.wards_gained}</td>
                <td class="text-right tabular-nums">{province.wards_lost}</td>
                <td class={[
                  "text-right tabular-nums font-medium",
                  delta_class(province.wards_gained - province.wards_lost)
                ]}>
                  {format_delta(province.wards_gained - province.wards_lost, :count)}
                </td>
                <td class="text-right tabular-nums">{province.councils_gained}</td>
                <td class="text-right tabular-nums">{province.councils_lost}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="space-y-6">
        <h2 class="text-xl font-semibold">Councils</h2>
        <.municipality_table
          id="municipalities-gained"
          title="Majority gained"
          rows={@municipalities[:gained] || []}
          parties={@parties}
          party_id={@party_id}
          previous_year={@previous_year}
          other_label="Taken from"
          other_control={:previous_control}
        />
        <.municipality_table
          id="municipalities-lost-to-party"
          title="Majority lost to another party"
          rows={@municipalities[:lost_to_party] || []}
          parties={@parties}
          party_id={@party_id}
          previous_year={@previous_year}
          other_label="Now held by"
          other_control={:control}
        />
        <.municipality_table
          id="municipalities-lost-hung"
          title="Majority lost to a hung council"
          rows={@municipalities[:lost_hung] || []}
          parties={@parties}
          party_id={@party_id}
          previous_year={@previous_year}
          other_label="Now"
          other_control={:control}
        />
        <.municipality_table
          id="municipalities-pending"
          title={"Held in #{@previous_year} · #{@live_year} count in progress"}
          rows={@municipalities[:pending] || []}
          parties={@parties}
          party_id={@party_id}
          previous_year={@previous_year}
          other_label="Leading now"
          other_control={:control}
          counting
        />
        <.municipality_table
          id="municipalities-kept"
          title="Majority kept"
          rows={@municipalities[:kept] || []}
          parties={@parties}
          party_id={@party_id}
          previous_year={@previous_year}
          collapsed
        />
      </section>

      <section class="space-y-6">
        <h2 class="text-xl font-semibold">Wards</h2>
        <p :if={@overview.wards == []} class="opacity-60">
          No ward results yet. The party file is fetched when the page opens.
        </p>
        <.ward_table
          id="wards-gained"
          title="Gained"
          rows={@wards[:gained] || []}
          parties={@parties}
          previous_year={@previous_year}
          other_label="Taken from"
          other_party={:previous_holder}
        />
        <.ward_table
          id="wards-lost"
          title="Lost"
          rows={@wards[:lost] || []}
          parties={@parties}
          previous_year={@previous_year}
          other_label="Lost to"
          other_party={:holder}
        />
        <.ward_table
          id="wards-pending"
          title={"Held in #{@previous_year} · #{@live_year} result not declared yet"}
          rows={@wards[:pending] || []}
          parties={@parties}
          previous_year={@previous_year}
          collapsed
        />
        <.ward_table
          id="wards-held"
          title="Held"
          rows={@wards[:held] || []}
          parties={@parties}
          previous_year={@previous_year}
          collapsed
        />
      </section>
    </Layouts.app>
    """
  end

  attr :overview, :map, required: true
  attr :municipalities, :map, required: true
  attr :wards, :map, required: true
  attr :previous_year, :integer, required: true

  defp stats(assigns) do
    assigns =
      assign(assigns,
        national: assigns.overview.national,
        previous: assigns.overview.previous_national
      )

    ~H"""
    <section id="party-stats" class="grid gap-4 grid-cols-2 lg:grid-cols-4">
      <.stat label="Votes" value={format_number(@national && @national.total_valid_votes)}>
        {@previous_year}: {format_number(@previous && @previous.total_valid_votes)}
      </.stat>
      <.stat label="Share" value={format_percentage(@national && @national.vote_percentage)}>
        <span class={delta_class(share_swing(@national, @previous))}>
          {format_delta(share_swing(@national, @previous), :points)} pp
        </span>
        vs {format_percentage(@previous && @previous.vote_percentage)}
      </.stat>
      <.stat label="Seats" value={format_number(@national && @national.total_seats_won)}>
        {@previous_year}: {format_number(@previous && @previous.total_seats_won)}
      </.stat>
      <.stat label="Ward seats" value={format_number(@national && @national.ward_seats_won)}>
        {@previous_year}: {format_number(@previous && @previous.ward_seats_won)}
      </.stat>
      <.stat label="Majority councils" value={format_number(@national && @national.majority_won)}>
        {@previous_year}: {format_number(@previous && @previous.majority_won)}
      </.stat>
      <.stat
        label="Councils gained / lost"
        value={"#{count(@municipalities, :gained)} / #{count(@municipalities, [:lost_to_party, :lost_hung])}"}
      >
        {count(@municipalities, :kept)} kept · {count(@municipalities, :pending)} counting
      </.stat>
      <.stat
        label="Wards gained / lost"
        value={"#{count(@wards, :gained)} / #{count(@wards, :lost)}"}
      >
        {count(@wards, :held)} held · {count(@wards, :pending)} not declared
      </.stat>
      <.stat label="Wards contested" value={format_number(length(@overview.wards))}>
        in {length(@overview.municipalities)} municipalities
      </.stat>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  slot :inner_block

  defp stat(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 p-4">
      <div class="text-sm opacity-60">{@label}</div>
      <div class="text-2xl tabular-nums">{@value}</div>
      <div class="text-sm opacity-75 tabular-nums">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :total, :integer, required: true
  attr :items, :list, required: true, doc: "`{party_id | :hung | nil, count}`, most first"
  attr :parties, :map, required: true
  attr :footnote, :string, default: nil

  # A stacked bar of where the rows went (or came from), with a legend.
  defp breakdown_card(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 p-4 space-y-3">
      <div class="flex items-baseline justify-between">
        <h3 class="font-medium">{@title}</h3>
        <span class="text-2xl tabular-nums">{@total}</span>
      </div>
      <div :if={@items != []} class="flex h-3 w-full overflow-hidden rounded-full bg-base-200">
        <div
          :for={{key, count} <- @items}
          style={"width: #{count / max(@total, 1) * 100}%; background-color: #{breakdown_colour(@parties, key)}"}
          title={"#{breakdown_label(@parties, key)}: #{count}"}
        />
      </div>
      <ul class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
        <li :for={{key, count} <- @items} class="inline-flex items-center gap-2">
          <.party_label :if={is_integer(key)} parties={@parties} party_result={%{party_id: key}} />
          <span :if={key == :hung} class="badge badge-warning badge-sm">hung</span>
          <span :if={is_nil(key)} class="opacity-60">another party</span>
          <span class="tabular-nums">{count}</span>
        </li>
      </ul>
      <p :if={@items == []} class="text-sm opacity-60">None so far.</p>
      <p :if={@footnote} class="text-sm opacity-60">{@footnote}</p>
    </div>
    """
  end

  defp breakdown_colour(parties, party_id) when is_integer(party_id),
    do: party_colour(parties, %{party_id: party_id})

  defp breakdown_colour(_parties, :hung), do: "var(--color-warning)"
  defp breakdown_colour(_parties, nil), do: "var(--color-base-300)"

  defp breakdown_label(parties, party_id) when is_integer(party_id),
    do: party_abbreviation(parties, %{party_id: party_id})

  defp breakdown_label(_parties, :hung), do: "hung"
  defp breakdown_label(_parties, nil), do: "another party"

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :party_id, :integer, required: true
  attr :previous_year, :integer, required: true
  attr :other_label, :string, default: nil
  attr :other_control, :atom, default: nil
  attr :counting, :boolean, default: false
  attr :collapsed, :boolean, default: false

  defp municipality_table(assigns) do
    ~H"""
    <details
      id={@id}
      open={not @collapsed and @rows != []}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="cursor-pointer font-medium">
        {@title} <span class="badge badge-sm">{length(@rows)}</span>
      </summary>
      <div :if={@rows != []} class="overflow-x-auto mt-2">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Municipality</th>
              <th class="text-right">Share</th>
              <th class="text-right">{@previous_year}</th>
              <th class="text-right">Swing</th>
              <th class="text-right">Seats</th>
              <th class="text-right">{@previous_year}</th>
              <th :if={@other_label}>{@other_label}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"#{@id}-#{row.municipality_id}"}>
              <td>
                <.link navigate={~p"/municipalities/#{row.municipality_id}"} class="link">
                  {row.name}
                </.link>
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
              <td :if={@other_label}>
                <.council_control
                  parties={@parties}
                  party_id={@party_id}
                  control={Map.get(row, @other_control)}
                  counting={@counting}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :other_label, :string, default: nil
  attr :other_party, :atom, default: nil
  attr :collapsed, :boolean, default: false

  defp ward_table(assigns) do
    ~H"""
    <details
      id={@id}
      open={not @collapsed and @rows != []}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="cursor-pointer font-medium">
        {@title} <span class="badge badge-sm">{length(@rows)}</span>
      </summary>
      <div :if={@rows != []} class="overflow-x-auto mt-2">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Ward</th>
              <th class="text-right">Share</th>
              <th class="text-right">{@previous_year}</th>
              <th class="text-right">Swing</th>
              <th :if={@other_label}>{@other_label}</th>
              <th>Declared</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"#{@id}-#{row.ward_id}"}>
              <td>
                <.link
                  :if={row.municipality_id}
                  navigate={~p"/municipalities/#{row.municipality_id}"}
                  class="link"
                >
                  {row.municipality_name}
                </.link>
                <span :if={is_nil(row.municipality_id)}>{row.municipality_name}</span>
                · ward {row.ward_number}
                <span :if={row.new_ward} class="badge badge-ghost badge-sm">new ward</span>
              </td>
              <td class="text-right tabular-nums">{format_percentage(row.share)}</td>
              <td class="text-right tabular-nums opacity-60">
                {format_percentage(row.previous_share)}
              </td>
              <td class={["text-right tabular-nums", delta_class(row.swing)]}>
                {format_delta(row.swing, :points)}
              </td>
              <td :if={@other_label}>
                <.party_label
                  :if={Map.get(row, @other_party)}
                  parties={@parties}
                  party_result={%{party_id: Map.get(row, @other_party)}}
                />
                <span :if={is_nil(Map.get(row, @other_party))} class="opacity-60">
                  another party
                </span>
              </td>
              <td class="tabular-nums opacity-75"><.declared_at ward={row} /></td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end
end
