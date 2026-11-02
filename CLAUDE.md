# Fore the V — notes for Claude

This repo **is the live tour site**: https://stevepc95.github.io/fore-the-v/ (GitHub Pages, `main` branch, root).
The old Claude artifact link is retired and only shows a "We've moved" banner. Make every site change here.

## How it's built
- `index.html` holds the whole site (HTML, CSS and JS). Tabs are `section[data-view]`, routed by `#hash`.
- Supabase backs sign-in, photos, dop videos, fourball pairings, the Wolf wheel and live scoring (`config.js` holds the public URL and anon key). Schema scripts run in order: `supabase/setup.sql`, `002`…`011`.
- Sign-in: pick Fore the Boys, enter the group code, pick your name. The Tour V code is optional and only unlocks score entry, captains' picks and the Wolf wheel. Sessions are remembered on the phone (anonymous Supabase auth + `members` table).
- Log a Dop is for fun (no points): any signed-in member films up to 30 s in-app; videos in the private `dops` bucket. Photos in the private `photos` bucket (General album).
- The Bookie (`#bookie`, scripts 009 + 010): fake-money betting. Each of the 8 starts on R1,000,000; past tourists can buy in (`bookie_joins`). **Fixed odds against the house** (010 replaces 009's tote): odds per answer on `markets.odds` (null = answers × 0.9), each bet locks its odds, win = stake × odds. Steve (is_admin) posts markets, sets odds, closes betting, posts answers. Pitched markets (`market_suggestions`) cost R50k; declined = gone, approved = opening bet at double odds (`bets.boost` = 2). The Casino = European roulette spun in `ftv_spin`. All money checks happen in the database functions, never in the browser; balance = `ftv_balance()`.
- Practice Green (`#putt`): canvas one-putt game behind a Start putting lock (so scrolling can't fire a putt); stats in localStorage only (`ftv-putt`). Fixed 60 Hz physics so putts can be simulated. Joke rule (Steve): a dropping putt has a 20% chance (`CURSE_CHANCE`) to lip out round the cup and start a secret 6-putt curse; putts 2-5 are rigged at release (`rig()`: slightly less pace or a fraction of a degree) so they die on the lip or shave the edge; on the 6th a bong swats the ball and sits centre screen smoking, message "Hahahahaha got you". Never show the word "bong" on screen.
- Scoring: shots per hole are stored; Stableford points are calculated in the browser from par, stroke index (course cards in the scoring script) and full handicap. Friday = Wolf (calls in `wolf_calls`), Saturday = Cha Cha Cha (best 1/2/3 staggered). Rounds can be locked by captains/Steve.
- Exec-only tabs (Fines, Planning) are shown to Steve, Nic, Brandon, Guy with a "Hidden tab" flag. Their fine ideas (golf / general / random) and planning items live in `exec_items` (script 007), shared and live; before 007 runs, Fines shows the draft list and Planning falls back to on-phone ticks.
- Test profile (script 011): `steve_test` ("Steve Test", `players.is_test`) is a regular non-admin punter. Only reachable from an admin phone via Account > Switch to test profile (`ftv_switch_test`; `members.test_of` remembers the real player; a trigger blocks picking it at sign-in). Its bets, spins and pitches are hidden from everyone except itself and Steve; `ftv_test_reset` wipes them. Hidden from the sign-in list (ids ending `_test`).
- Codes live in Supabase (`tour_secret`), never in this repo.
- Installable via Add to Home Screen (`manifest.webmanifest`, `icons/`).
- Push to `main` and the site updates in about a minute.
- Supabase project id `hlzmprtoofinzvzinvtf`. When the Supabase connector is attached, run non-destructive SQL directly with `execute_sql` (creates, inserts, `create or replace`). `apply_migration` and anything with drop/delete ask for a confirmation that Steve's mobile app auto-cancels, so hand him those as a script file to paste into the SQL Editor. Always keep the matching `supabase/0NN_*.sql` file in the repo up to date.

## Design rules (keep it looking paid-for)
- Use the colour and font tokens in the `:root` block; never hard-code a colour that only works in light or dark mode.
- Inland = jacaranda purple (`--inland`), Coastal = ocean teal (`--coastal`), club green masthead, gold `--flag` for highlights and TBC chips.
- Fonts: Big Shoulders Display (headings), Instrument Sans (body), IBM Plex Mono (labels, times), Permanent Marker (nicknames only), Libre Baskerville (FTB badge and honours board only).
- New sections follow the existing pattern: `.head` (eyebrow + `h2`), then `.card`s; reuse existing components before inventing new ones.
- Must work on a phone at 360px wide with no sideways scroll.

## Content rules
- Golf formats, schedule and logistics come from Nic, Brandon and Guy. Don't change or "improve" them; mark gaps as TBC.
- The project's "Tour Bible" doc is the source of truth for facts.
