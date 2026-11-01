# Fore the V — notes for Claude

This repo **is the live tour site**: https://stevepc95.github.io/fore-the-v/ (GitHub Pages, `main` branch, root).
The old Claude artifact link is retired and only shows a "We've moved" banner. Make every site change here.

## How it's built
- `index.html` holds the whole site (HTML, CSS and JS). Tabs are `section[data-view]`, routed by `#hash`.
- Dop log: Supabase (`config.js` holds the public URL and anon key). Writes only go through the PIN functions in `supabase/setup.sql`; the PIN lives in Supabase, never in this repo.
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
