# Scotland 2028 trip site

Live at https://greatscot28.com. One static file, no build step.

## Layout
- `index.html`: the whole site. All trip data is in the labelled block at the top of the `<script>`. It is the single source of truth.
- `supabase/migrations/`: every database change, numbered in order. `0001` and `0002` were run by hand before tracking began; from `baseline_marker` (Oct 5, 2026) on, each file matches a migration applied through the Supabase connector.
- `.vercelignore`: keeps everything except the site itself off the public domain.

## How a change ships
1. Work on a branch named `claude/<short-description>`, never directly on `main`.
2. Push the branch. Vercel builds a preview link for it.
3. The organiser checks the preview on a phone, then says "ship it".
4. Merge to `main`. Vercel deploys to greatscot28.com within a minute.
5. Copy the shipped `index.html` back to the Claude project (`site/index.html`) as the backup.

Small copy or data fixes may go straight to `main` when the organiser says so.

## Database (Supabase project `Scotland-2028`, ref `rqqqpwywswxcjyqlwdbr`)
- Apply changes as named migrations and save the same SQL here as the next numbered file, in the same commit as any `index.html` change that depends on it.
- Order: database first, then the site. Keep old function signatures working until the new site is live.
- Additive changes (new tables, columns, functions) can be applied as part of the request.
- Anything that alters or removes existing data (ballots, expenses, traveler details, codes) is shown to the organiser first and waits for a yes.
- Never read, print or commit the group and admin codes in `trip_settings`.
- After each schema change, run the security advisor.
- The site has no logins by design. Functions are callable with the publishable key and check codes themselves.

## Things that break quietly
- Do not rename a `VOTES` id or a caddie key in `index.html` after people have voted; answers are stored under those names.
- `TRIP.passportMin` in `index.html` and the date inside `traveler_status()` must change together.
- The golfer id list is hard-coded in `submit_ballot`, `retract_ballot` and `save_details`, and in `GOLFERS` in `index.html`.
- Bump `TRIP.updated` in `index.html` whenever the site content changes.
