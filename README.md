# IEC results

A realtime dashboard that follows South Africa's 2026 Local Government Elections count
live from the Electoral Commission (IEC), keeps a timestamped history of every change, and
compares every area, party, council and ward with 2021.

It is written in [Elixir](https://elixir-lang.org) ([how to install
Elixir](https://elixir-lang.org/install.html)), with
[Phoenix LiveView](https://www.phoenixframework.org) and PostgreSQL. It is meant to run
on your own machine: there is no auth.

![The winners and losers page during the count](docs/winners-and-losers.png)

The design (who it is for, the look, how pages are built, phones) is in
[docs/design.md](docs/design.md).

## Getting started

You need Elixir 1.17+ with Erlang/OTP (the Elixir guide covers both) and PostgreSQL:

- Elixir: see [Installing Elixir](https://elixir-lang.org/install.html)
- PostgreSQL: see [PostgreSQL downloads](https://www.postgresql.org/download/)

Then, from this directory:

    mix setup        # dependencies, database, first seed, assets
    mix phx.server   # http://localhost:4000

`mix setup` creates the database and runs `mix iec.seed` once, which fills it from the
IEC's feed (about two minutes, most of it the ward directory).

The development database defaults to `postgres`/`postgres` on localhost, database
`iec_dev`. To use another one, set `DATABASE_URL`:

    export DATABASE_URL=ecto://user:password@localhost/iec_dev

## Seeding

**You do not have to seed by hand.** When the server starts it does the same work in the
background: it refreshes the party list, imports the 2021 results (once), starts polling
the live feeds and party files, and fills the ward directory. Pages fill in over the first
minute or two.

`mix iec.seed` does all of it up front, in one go, without starting the pollers:

    mix iec.seed

1. Party names and colours (`PartyList.js`)
2. The 2021 final results: national, every province and municipality
3. The 2026 results so far
4. Map outlines for provinces, municipalities and wards, and the 2021 wards (about 80 MB)
   and town and suburb names from OpenStreetMap, each placed in its ward (four Overpass
   queries, once; see below)
5. The 2026 municipality files: which municipality each ward is in, and every party
   standing (about 520), which the app then follows
6. The 2021 municipality files: every party's result in every ward, and its winner
7. The 2026 and 2021 files of every party standing

Every step is idempotent, so it is safe to run again (for example after the count, when
nothing is being polled any more), and safe to run while the server is up. Ward files the
IEC has not published yet are retried, and the server keeps retrying any that are missing
every 10 minutes.

To start again from nothing: `mix ecto.reset`.

## Pages

- `/`: national progress, parties vs 2021, a map of who leads each municipality, provinces,
  latest changes
- `/map`: the map at province, municipality or ward level, for the whole country or one
  province: each area in its leading party's colour (stronger for a bigger lead,
  hatched while counting), only the areas that changed hands since 2021, close contests
  (shaded by the lead over the runner-up) or spoilt ballots (provinces and
  municipalities; the IEC publishes no ward figure). Scroll, pinch or use the buttons to
  zoom, drag to move, hover for details, click to open an area (on a phone, tap once for
  details and again to open)
- `/provinces/:id`: parties vs 2021, a map of its municipalities, and each municipality's
  council control and leader, now and in 2021
- `/municipalities/:id`: a dashboard: council control now and in 2021, voters, ballots,
  spoilt ballots and seats against 2021, the vote share since 2000, wards won per party
  against who won the same wards in 2021, every ward to pick from, the closest wards and
  those that changed hands, every followed party vs 2021, a ward map, each ward's winner
  now and in 2021, and the change history
- `/wards` (the search link in the header): find a ward by suburb or town ("Meadowridge"),
  or by municipality or city and ward
  number ("Pretoria 45", "tswane 12", "EC153 18"), or by its IEC ward id. Misspellings
  and half-typed names still match; the big cities and towns are known by their own names
  (Durban, Gqeberha, Soweto). Enter opens the best match, the arrow keys move through the
  results. A municipality alone lists its wards in their leaders' colours. The IEC names
  wards by number only, so suburbs and streets find nothing
- `/wards/:id`: a ward's dashboard: who won or leads it and by how much, against 2021,
  every party's share, swing and share of the whole council, the ward since 2021 and its
  council since 2000 as charts, who runs the council, a map of it and the wards around it
  (in any municipality) and those wards' results. Every ward on a map or in a table opens
  it
- `/parties/:id` (click any party name): stats vs 2021, who it lost wards and councils to
  and gained them from, net change per province, and the councils and wards behind that
- `/trends`: every local election since 2000 (imported once): vote share, seats won and
  councils with a majority per party, registered voters and ballots, and each province
  as a small chart; 2026 is dashed while its count runs
- `/movers`: biggest winners and losers by vote share swing, wards and council
  majorities changing hands per party, and the biggest local surges and collapses
- `/contests`: close contests: the narrowest council contests (lead in points and votes, and
  against 2021) as cards and a table, and every ward closest first. Ward leads come from
  the party files' shares of all the ward's votes, so a ward whose winner trails on them
  (some independents) is left out
- `/changes`: every change, filterable by level
- `/status`: the feeds, what has been imported and the server, live; `/health` gives a
  short JSON summary for uptime checks
- `/about`: what this is and is not, data sources and credits, how it works and how to
  read it

Every page updates live, and a sticky footer shows how far the count is and when the feed
was last checked. Every table sorts by any column: click a heading, click again to
reverse.

## Where the data comes from

The IEC has an official API (api.elections.org.za), but it needs credentials from the IEC.
This app reads what the public results dashboard at results.elections.org.za reads
instead: static JSON files under
`https://results.elections.org.za/dashboards/lge/MapsJason/<year>/`.

| File | Contents |
| --- | --- |
| `EEID1887LiteMapsNational.js` | national totals, every party, progress counters |
| `EEID1887Province<1-9>.js` | a province with every party, its municipalities with the top 3 |
| `EEID1887Party<id>.js` | one party: share, seats and majority per municipality, share and win per ward |
| `EEID1887Munic<id>.js` | one municipality with every ward and voting district (up to ~3 MB; only read for the ward directory) |
| `PartyList.js` | party id → abbreviation, full name, colour |

Map outlines come from the IEC's election map,
`https://results.elections.org.za/ElectionMap/MapData/<year>/` (`nationalProvince.js`, `nationalMunic.js`, `nationalWard.js`, GeoJSON). They are
projected, simplified and stored once as SVG paths (`Iec.Maps.Geometry`), so the maps are
plain server-rendered SVG: on each update LiveView sends only the areas whose colour changed.
The live websocket is compressed, and long lists render 25 rows until you ask for more.

The event ids (`EEID1887` for 2026, `EEID1091` for 2021) come from `var EEID2026` and
friends in the dashboard's `LGEResultsDashboard.aspx`; they live in `config/config.exs`.
This is an undocumented feed, so its shape may change.

### Polling politely

Each file has its own poller (`Iec.Results.Poller`), using Req. Every request sends
`If-None-Match` / `If-Modified-Since` from the previous response, so an unchanged file
costs a bodyless `304`. The next request is scheduled for when Cloudflare's cached copy
expires (`Cache-Control: max-age`, 60s, minus the response's `Age`), never sooner than 15s.
Failures back off from 30 seconds to 5 minutes.

The IEC rewrites its files every one to two minutes, and the figures in them are a few
minutes old, so the app is about as live as the IEC's own dashboard.

### Town and suburb names

The IEC names wards by municipality and number only, so "Meadowridge" would find nothing.
Town and suburb names come from OpenStreetMap (© OpenStreetMap contributors, ODbL,
credited on `/about`): cities, towns, villages, hamlets, suburbs, neighbourhoods and
quarters, read once through the Overpass API and stored in `places` (`Iec.Places`). Each
is a point (an area at its centre), placed in the live ward whose outline holds it, so a
suburb reaching into a neighbouring ward finds the ward with its centre. Searching never
calls Overpass.

`Iec.Places.Overpass` keeps to the
[public instance's usage policy](https://wiki.openstreetmap.org/wiki/Overpass_API#Public_Overpass_API_instances):
four queries (South Africa in four tiles), one at a time, each only once `/api/status`
reports a free slot (waiting as long as it says), backing off from 30 seconds to 10 minutes
on a busy answer, and on giving up trying again two hours later rather than pressing it.
Requests name the site in their User-Agent.

## How the history works

- `fetches`: every download with new content. National and province files keep their
  gzipped body, so the history can be re-read if the parser changes.
- `snapshots`: one row per area each time its figures change (the IEC's report time alone
  does not count). `previous_snapshot_id` links to the area's previous snapshot and
  `inserted_at` is when the change was seen. The 2021 results sit in the same tables with
  `election = 2021`.
- `party_results`: each party's votes and seats per snapshot.
- `party_municipality_results`, `party_ward_results`: from the party files.
  `first_won_at` is when a ward was first seen declared; wards already declared when
  tracking began show "before <time>".
- `wards`: ward → municipality. The party files nest every ward under the province's
  first municipality, so this comes from the municipality files.
- `followed_parties`: every party standing, found in the municipality files. Parties on the
  national list are polled as their files change, the rest every five minutes, so every
  ward's winner is known. Opening a page never makes the app contact the IEC.
- `boundaries`: map outlines per election. A 2026 ward is `redrawn` when the 2021 ward
  with its id covers a clearly different area (its area changed by more than about a
  fifth, or the outlines' bounding boxes overlap by less than 75%). New and redrawn wards
  are listed as "new or redrawn wards won", not as gained or lost, and the map's "changed
  since 2021" view leaves them out.
- `parties`: names and colours.

## Deploying

It runs on Fly.io at https://iec-results.fly.dev (`fly.toml`, `Dockerfile`, Johannesburg). A
first deploy needs a Postgres attached and a secret key, both kept as Fly secrets and
never in the repo:

    fly postgres create --name iec-results-db --region jnb
    fly postgres attach iec-results-db --app iec-results
    fly secrets set SECRET_KEY_BASE="$(mix phx.gen.secret)" --app iec-results
    fly deploy

Migrations run on each deploy, and the app seeds itself in the background on start
(about five minutes on an empty database). It must keep one machine running, since it
polls the IEC around the clock.

## Tests

    mix test

The tests stub every IEC request with `Req.Test`, so they run offline.

## Licence

MIT. See [LICENSE](LICENSE).
