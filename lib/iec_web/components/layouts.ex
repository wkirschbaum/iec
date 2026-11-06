defmodule IecWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use IecWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  # Footer figures before the first national poll: everything shows as a dash.
  @no_progress Map.new(
                 [
                   :voting_districts_complete,
                   :voting_districts_expected,
                   :wards_complete,
                   :wards_expected,
                   :municipalities_complete,
                   :municipalities_expected,
                   :seats_complete,
                   :seats_expected,
                   :total_votes_cast,
                   :report_date
                 ],
                 &{&1, nil}
               )

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :active, :atom, default: nil, doc: "the page the navigation marks as current"

  attr :count_progress, :map,
    default: nil,
    doc: "national count progress from IecWeb.LiveUpdates, shown in the sticky footer"

  attr :feed_status, :map,
    default: nil,
    doc: "`%{feeds, failing, checked_at}` from IecWeb.LiveUpdates, shown in the header"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :no_progress, @no_progress)

    ~H"""
    <header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/85 backdrop-blur-xl">
      <div class={[container(), "flex h-16 items-center gap-8"]}>
        <.link navigate={~p"/"} class="flex shrink-0 items-center gap-3">
          <span class="grid size-8 place-items-center rounded-lg bg-primary text-primary-content shadow-sm">
            <.icon name="hero-check-micro" class="size-5" />
          </span>
          <span class="leading-tight">
            <span class="block font-serif text-lg font-semibold tracking-tight">Results Desk</span>
            <span class="block text-[0.62rem] uppercase tracking-[0.16em] text-base-content/55">
              South Africa · Local {Iec.Results.live_year()}
            </span>
          </span>
        </.link>
        <nav class="hidden items-center gap-1 text-sm lg:flex">
          <.nav_link :for={{label, path, page} <- nav_items()} path={path} active={@active == page}>
            {label}
          </.nav_link>
        </nav>
        <div class="ml-auto flex items-center gap-3">
          <.link
            navigate={~p"/wards"}
            id="find-ward"
            aria-label="Find your ward"
            title="Find your ward"
            class={[
              "inline-flex min-h-10 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full px-3 text-sm transition-colors",
              @active == :wards && "bg-base-content font-medium text-base-100",
              @active != :wards && "text-base-content/60 hover:bg-base-200 hover:text-base-content"
            ]}
          >
            <.icon name="hero-magnifying-glass-micro" class="size-4" />
            <%!-- Beside the full navigation there is room for the icon only. --%>
            <span class="hidden sm:inline lg:hidden">Find your ward</span>
          </.link>
          <.link
            navigate={~p"/about"}
            class={[
              "inline-flex min-h-10 items-center rounded-full px-3 text-sm transition-colors",
              @active == :about && "bg-base-content font-medium text-base-100",
              @active != :about && "text-base-content/60 hover:bg-base-200 hover:text-base-content"
            ]}
          >
            About
          </.link>
          <div class="hidden sm:block"><.theme_toggle /></div>
        </div>
      </div>
    </header>

    <main class={[
      "py-8 sm:py-10",
      (@count_progress || @feed_status) && "pb-44 lg:pb-32"
    ]}>
      <div class={[container(), "space-y-12"]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.count_footer
      :if={@count_progress || @feed_status}
      progress={@count_progress || @no_progress}
      feed_status={@feed_status}
      active={@active}
    />

    <.flash_group flash={@flash} />
    """
  end

  attr :progress, :map, required: true
  attr :feed_status, :map, default: nil
  attr :active, :atom, default: nil

  # The sticky count footer: a bar that grows as voting districts report (set slightly
  # below the footer's top border), the headline percentage, rings for the other counters
  # and the votes counted so far. Bar and rings animate on each live update.
  defp count_footer(assigns) do
    assigns =
      assign(assigns,
        percentage:
          IecWeb.ResultsComponents.percentage_of(
            assigns.progress.voting_districts_complete,
            assigns.progress.voting_districts_expected
          )
      )

    ~H"""
    <footer
      id="count-footer"
      phx-hook=".CountPulse"
      class="fixed inset-x-0 bottom-0 z-40 border-t border-base-300 bg-base-100/90 pb-[env(safe-area-inset-bottom)] backdrop-blur-xl"
    >
      <div data-pulse class="pointer-events-none absolute inset-0 bg-primary opacity-0" />
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CountPulse">
        // A faint wash of the accent when the count moves; restarts if updates come quickly.
        export default {
          mounted() {
            const wash = this.el.querySelector("[data-pulse]")
            this.handleEvent("count-updated", () => {
              if (matchMedia("(prefers-reduced-motion: reduce)").matches) return
              wash.classList.remove("count-pulse")
              void wash.offsetWidth
              wash.classList.add("count-pulse")
            })
          }
        }
      </script>
      <div class="pt-1.5">
        <div class="h-1 w-full bg-base-300/50">
          <div
            id="count-footer-bar"
            class="relative h-full rounded-r-full bg-gradient-to-r from-primary/40 to-primary transition-[width] duration-1000 ease-out"
            style={"width: #{@percentage}%"}
          >
            <span class="absolute -right-1.5 -top-1 size-3 rounded-full bg-primary ring-2 ring-base-100 shadow-[0_0_14px] shadow-primary motion-safe:animate-pulse" />
          </div>
        </div>
      </div>

      <div class={[container(), "flex items-center gap-6 py-2 md:py-2.5"]}>
        <div class="flex items-baseline gap-2">
          <span class="font-serif text-2xl font-semibold tabular-nums tracking-tight text-primary md:text-3xl">
            {IecWeb.ResultsComponents.format_progress(@percentage)}
          </span>
          <span class="eyebrow">counted</span>
        </div>

        <div class="hidden items-center gap-5 md:flex">
          <.count_ring
            label="Districts"
            complete={@progress.voting_districts_complete}
            expected={@progress.voting_districts_expected}
          />
          <.count_ring
            label="Wards"
            complete={@progress.wards_complete}
            expected={@progress.wards_expected}
          />
          <.count_ring
            label="Councils"
            complete={@progress.municipalities_complete}
            expected={@progress.municipalities_expected}
          />
          <.count_ring
            label="Seats"
            complete={@progress.seats_complete}
            expected={@progress.seats_expected}
          />
        </div>

        <div class="ml-auto text-right leading-tight">
          <div class="text-sm font-medium tabular-nums">
            {IecWeb.ResultsComponents.format_number(@progress.total_votes_cast)}
            <span class="font-normal opacity-60">votes</span>
          </div>
          <div class="flex items-center justify-end gap-3 text-xs tabular-nums">
            <.feed_indicator :if={@feed_status} status={@feed_status} />
            <span class="hidden whitespace-nowrap opacity-60 sm:inline">
              IEC report {IecWeb.ResultsComponents.format_clock(@progress.report_date)}
            </span>
          </div>
        </div>
      </div>

      <%!-- On phones the navigation sits here, within thumb reach. --%>
      <nav class="grid grid-cols-6 border-t border-base-300 lg:hidden" aria-label="Sections">
        <.link
          :for={{label, path, page, icon} <- tab_items()}
          navigate={path}
          class={[
            "flex flex-col items-center gap-0.5 py-2 text-[0.68rem] font-medium transition-colors active:scale-95",
            @active == page && "text-primary",
            @active != page && "text-base-content/60"
          ]}
        >
          <.icon name={icon} class="size-5" />
          {label}
        </.link>
      </nav>
    </footer>
    """
  end

  defp tab_items do
    [
      {"Overview", ~p"/", :national, "hero-home"},
      {"Map", ~p"/map", :map, "hero-map"},
      {"Trends", ~p"/trends", :trends, "hero-presentation-chart-line"},
      {"Movers", ~p"/movers", :movers, "hero-arrows-up-down"},
      {"Contests", ~p"/close-contests", :contests, "hero-scale"},
      {"Changes", ~p"/changes", :changes, "hero-bolt"}
    ]
  end

  attr :label, :string, required: true
  attr :complete, :integer
  attr :expected, :integer

  defp count_ring(assigns) do
    assigns =
      assign(assigns,
        percentage: IecWeb.ResultsComponents.percentage_of(assigns.complete, assigns.expected)
      )

    ~H"""
    <div
      class="flex items-center gap-2"
      title={"#{IecWeb.ResultsComponents.format_number(@complete)} of #{IecWeb.ResultsComponents.format_number(@expected)}"}
    >
      <div class="relative size-8">
        <div class="absolute inset-0 rounded-full border-[3px] border-base-300" />
        <div
          class="radial-progress absolute inset-0 text-primary transition-all duration-1000 [--size:2rem] [--thickness:3px]"
          style={"--value: #{round(@percentage)}"}
          role="progressbar"
          aria-label={@label}
          aria-valuenow={round(@percentage)}
        />
      </div>
      <div class="leading-tight">
        <div class="text-[0.65rem] uppercase tracking-wider opacity-60">{@label}</div>
        <div class="text-sm font-medium tabular-nums">{round(@percentage)}%</div>
      </div>
    </div>
    """
  end

  attr :status, :map, required: true

  defp feed_indicator(assigns) do
    ~H"""
    <.link
      navigate={~p"/status"}
      id="feed-status"
      class="flex items-center gap-1.5 hover:underline"
      title="Feed status"
    >
      <span class={[
        "inline-block size-2 rounded-full",
        cond do
          @status.feeds == 0 -> "bg-base-300"
          @status.failing > 0 -> "bg-error"
          true -> "bg-success motion-safe:animate-pulse"
        end
      ]} />
      <span :if={@status.feeds == 0} class="opacity-60">Polling off</span>
      <span :if={@status.feeds > 0} class="whitespace-nowrap opacity-75">
        Live · checked {IecWeb.ResultsComponents.format_clock(@status.checked_at)}
        <span :if={@status.failing > 0} class="text-error">
          · {@status.failing}/{@status.feeds} failing
        </span>
      </span>
    </.link>
    """
  end

  # Header, page and footer share one container, so their left edges line up.
  defp container, do: "mx-auto w-full max-w-6xl px-4 sm:px-6 lg:px-8"

  defp nav_items do
    [
      {"Overview", ~p"/", :national},
      {"Map", ~p"/map", :map},
      {"Trends", ~p"/trends", :trends},
      {"Winners & losers", ~p"/movers", :movers},
      {"Close contests", ~p"/close-contests", :contests},
      {"Changes", ~p"/changes", :changes}
    ]
  end

  attr :path, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class={[
        "whitespace-nowrap rounded-full px-3 py-1.5 transition-colors",
        @active && "bg-base-content text-base-100 font-medium",
        !@active && "text-base-content/70 hover:bg-base-200 hover:text-base-content"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Theme: follow the system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Theme: light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Theme: dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
