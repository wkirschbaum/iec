# IEC results

An app that follows South Africa's 2026 Local Government Elections count
live from the Electoral Commission (IEC), keeps a timestamped history of every change, and
compares every area, party, council and ward with 2021.

It is written in [Elixir](https://elixir-lang.org), with
[Phoenix LiveView](https://www.phoenixframework.org) and PostgreSQL. It is meant to run
on your own machine: there is no auth.

![The winners and losers page during the count](docs/winners-and-losers.png)

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
4. The party files of every party on the national list, for 2026 and 2021
5. The ward directory: which municipality each ward is in (one file per municipality)

Every step is idempotent, so it is safe to run again (for example after the count, when
nothing is being polled any more), and safe to run while the server is up. Ward files the
IEC has not published yet are retried, and the server keeps retrying any that are missing
every 10 minutes.

To start again from nothing: `mix ecto.reset`.

## Pages

- `/`: national progress, parties vs 2021, provinces, latest changes
- `/provinces/:id`: parties vs 2021, and each municipality's council control and leader,
  now and in 2021
- `/municipalities/:id`: council control now and in 2021, every followed party vs 2021,
  each ward's winner now and in 2021, and the change history
- `/parties/:id` (click any party name): stats vs 2021, who it lost wards and councils to
  and gained them from, net change per province, and the councils and wards behind that
- `/movers`: biggest winners and losers by vote share swing, wards and council
  majorities changing hands per party, and the biggest local surges and collapses
- `/changes`: every change, filterable by level

Every page updates live, and a sticky footer shows how far the count is and when the feed
was last checked.

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
- `parties`: names and colours.

A ward's previous or new holder is only known for parties whose file is stored (the
national list, plus any party whose page has been opened), so a few show as "another
party".

## Tests

    mix test

The tests stub every IEC request with `Req.Test`, so they run offline.

## Licence

MIT. See [LICENSE](LICENSE).
