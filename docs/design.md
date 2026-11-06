# Design

## Who it is for

- **Newsroom live desks** following the count on a big screen: they need the answer at a
  glance, what just changed, and numbers they can quote.
- **Party agents and analysts**: where their party gained and lost, council by council
  and ward by ward.
- **Researchers**: sortable tables, comparisons with the previous election, honest
  caveats (redrawn wards, counts still running).
- **Engaged citizens**, mostly on phones: "who is winning where I live", in a minute.

They all need the same three things, in this order: **the answer** (who leads, by how
much, how far the count is), **what changed**, then **depth on demand**. And they need
to trust it: the source, the time of the IEC's last report and when we last checked are
always visible.

## Look

Editorial data journalism, in the spirit of FT, Bloomberg and The Economist results
pages: confident, calm, dense where it should be.

- **Type**: Newsreader (an editorial serif) for headlines and big numbers; Inter with
  tabular figures for data. Small uppercase labels (`.eyebrow`) name every figure.
- **Colour**: warm paper and ink in light mode, deep ink and warm white in dark mode.
  One accent, a deep teal, for live and progress; a brass highlight for the loading bar.
  Party colours are the only saturated colours on the page, so they carry meaning.
- **Surfaces**: hairline borders and a soft lift (`.panel`), generous spacing, no heavy
  boxes. Tables have quiet uppercase headings, hairline rows and figures that line up.
- **Motion**: bars, rings and map areas ease to their new values on every live update;
  nothing jumps or flickers. Hover raises cards slightly and nudges arrows.

## Structure

Every page opens the same way (`page_header`): a small label (live and how far the count
is, or "Final results"), a serif title, and a one-line summary written from the numbers
(`IecWeb.Narrative`), so the page says what matters before showing how.

- **Overview**: headline sentence; the vote share as one bar against the previous
  election; key figures; the map beside the standings; province cards; highlights; the
  full sortable table last.
- **Ward**: the same opening, written for the citizen asking "who won where I live": the
  winner and lead against the previous election, the ward and its council over time,
  then the parties, then the ward on a map among its neighbours and their results. Found
  from **Find your ward**, a search in the masthead that forgives spelling, knows cities
  by their own names and opens the best match on Enter.
- **Municipality**: a dashboard: the opening and key figures, then the long run since
  2000, wards won, every ward as a button to pick, the closest wards and those that
  changed hands, then the full tables.
- **Cards** carry a sparkline: a party's or an area's leader's share in every election.

**Clickable, never flaky**: every ward, municipality and party opens its page wherever it
appears, cards and rows are one link each (links never nest, so a tap goes where it
looks like it goes), and a map area opens on click but never after a drag.
- **Province, municipality, party**: the same opening, then their own sections, each
  under a serif section heading over a hairline rule.
- **Changes**: a digest, not a firehose. One card per update round with a summary line;
  leads changing hands and councils decided first; routine updates folded behind
  "Show the N areas". "Everything" is one click away.
- **Map, winners & losers**: controls are segmented pills; the map zooms and pans.

All text is generated from the live data and changes with it: "leads" becomes "wins"
and "Live · 76% counted" becomes "Final results" when the count completes.

## Phones

- Navigation moves to a **bottom tab bar** within thumb reach; the count strip sits just
  above it, with the safe area respected.
- Key figures fall into two columns; cards stack; segmented controls scroll sideways.
- Wide tables scroll sideways with their **first column pinned**.
- Touch targets are at least 40 px; taps press in slightly (`active:scale-95`).
- The map zooms with a pinch and pans with a drag; a drag never counts as a tap. The
  first tap on an area shows what it is, a second opens it.

## Where it lives

- Theme, fonts, `.panel`, `.eyebrow`, table styles: `assets/css/app.css`,
  `root.html.heex`.
- Masthead, footer, tab bar: `IecWeb.Layouts`.
- Page header, section heading, key figure, swing chip, vote-share bar, segmented
  control: `IecWeb.DesignComponents`.
- Generated sentences: `IecWeb.Narrative`; the changes digest: `IecWeb.ChangeDigest`.
