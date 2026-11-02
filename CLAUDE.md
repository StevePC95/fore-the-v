# Fore the V — notes for Claude

This repo **is the live tour site**: https://stevepc95.github.io/fore-the-v/ (GitHub Pages, `main` branch, root).
The old Claude artifact link is retired and only shows a "We've moved" banner. Make every site change here.

## How it's built
- `index.html` holds the whole site (HTML, CSS and JS). Tabs are `section[data-view]`, routed by `#hash`.
- Supabase backs sign-in, photos, dop videos, fourball pairings, the Wolf wheel and live scoring (`config.js` holds the public URL and anon key). Schema scripts run in order: `supabase/setup.sql`, `002`…`009`.
- Sign-in: pick Fore the Boys, enter the group code, pick your name. The Tour V code is optional and only unlocks score entry, captains' picks and the Wolf wheel. Sessions are remembered on the phone (anonymous Supabase auth + `members` table).
- Log a Dop is for fun (no points): any signed-in member films up to 30 s in-app; videos in the private `dops` bucket. Photos in the private `photos` bucket (General album).
- The Bookie (`#bookie`, script 009): fake-money prediction market. Each of the 8 starts on R1,000,000; Steve (is_admin) posts markets, closes betting and posts answers. Tote payouts (winners split the pot pro rata; nobody right or scrapped = refunds). All money checks happen in the `ftv_bet` / `ftv_market_*` functions, never in the browser.
- Scoring: shots per hole are stored; Stableford points are calculated in the browser from par, stroke index (course cards in the scoring script) and full handicap. Friday = Wolf (calls in `wolf_calls`), Saturday = Cha Cha Cha (best 1/2/3 staggered). Rounds can be locked by captains/Steve.
- Exec-only tabs (Fines, Planning) are shown to Steve, Nic, Brandon, Guy with a "Hidden tab" flag. Their fine ideas (golf / general / random) and planning items live in `exec_items` (script 007), shared and live; before 007 runs, Fines shows the draft list and Planning falls back to on-phone ticks.
- Codes live in Supabase (`tour_secret`), never in this repo.
- Installable via Add to Home Screen (`manifest.webmanifest`, `icons/`).
- Push to `main` and the site updates in about a minute.

## Design rules (keep it looking paid-for)
- Use the colour and font tokens in the `:root` block; never hard-code a colour that only works in light or dark mode.
- Inland = jacaranda purple (`--inland`), Coastal = ocean teal (`--coastal`), club green masthead, gold `--flag` for highlights and TBC chips.
- Fonts: Big Shoulders Display (headings), Instrument Sans (body), IBM Plex Mono (labels, times), Permanent Marker (nicknames only), Libre Baskerville (FTB badge and honours board only).
- New sections follow the existing pattern: `.head` (eyebrow + `h2`), then `.card`s; reuse existing components before inventing new ones.
- Must work on a phone at 360px wide with no sideways scroll.

## Content rules
- Golf formats, schedule and logistics come from Nic, Brandon and Guy. Don't change or "improve" them; mark gaps as TBC.
- The project's "Tour Bible" doc is the source of truth for facts.
