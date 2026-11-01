# Fore the V

The tour site for Fore the Boys V (Inland vs Coastal, 6–7 Nov 2026), as a standalone web app.
Anyone with the link can read it. Dops are logged with a shared tour PIN, no accounts needed.
On a phone, open the link and use **Share → Add to Home Screen** for an app icon.

## What's in here

| File | What it is |
|---|---|
| `index.html` | The whole site |
| `config.js` | Your Supabase URL and key (step 1) |
| `manifest.webmanifest`, `icons/` | Makes it installable as a home-screen app |
| `img/` | Last-tour photos |
| `supabase/setup.sql` | Creates the dop log database (step 1) |

## 1. Database (Supabase, free, ~10 min)

1. Sign up at supabase.com and create a new project (pick the region closest to SA, e.g. London or Frankfurt).
2. **SQL Editor → New query**: paste all of `supabase/setup.sql` and click **Run**.
3. In a new query, set the real PIN (don't save it in the repo):
   ```sql
   update public.tour_secret set pin = '1234' where id = 1;
   ```
4. **Project Settings → API**: copy the **Project URL** and the **anon / publishable key** into `config.js`.

## 2. Website (GitHub Pages, free, ~5 min)

From this folder in Claude Code (or a terminal):

```bash
git init && git add . && git commit -m "Fore the V"
gh repo create fore-the-v --public --source=. --push
```

Then on GitHub: **Settings → Pages → Build and deployment → Deploy from a branch → `main` / root → Save**.
After a minute the site is live at `https://<your-username>.github.io/fore-the-v/`.

## 3. Test before sharing

1. Open the link on your phone. The **Log a Dop** board should say **Practice**.
2. Log a test dop with the PIN; it should appear in the dop log on a second phone within seconds.
3. Use **Clear practice dops** to wipe the tests. Anything logged before Fri 12:00 is practice and never counts.

## Updating

Edit, then `git add . && git commit -m "update" && git push`. GitHub Pages redeploys in about a minute.

## Notes

- The repo is public, so the code, bios and photos can be seen by anyone who finds it. The page tells Google not to index it.
- The URL and key in `config.js` are meant to be public. The database only lets the site read dops; logging, removing and clearing all check the PIN inside Supabase.
- Exec Q ticks still save only on each person's own phone.
