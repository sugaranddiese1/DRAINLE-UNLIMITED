# Blaidle multiplayer setup

Blaidle stays a static GitHub Pages site. Supabase supplies anonymous authentication, private two-player rooms, authoritative mystery-song selection, database transactions, and realtime room updates.

## One-time setup

1. Create a free project at https://supabase.com/dashboard.
2. In **Authentication → Providers → Anonymous**, enable anonymous sign-ins.
3. Open **SQL Editor**, run `supabase/setup.sql`, and then run `supabase/seed-songs.sql`.
4. Open **Project Settings → API** and copy the Project URL and publishable/anon key.
5. Paste those two public values into `supabase-config.js`:

```js
window.BLAIDLE_SUPABASE={
  url:"https://YOUR-PROJECT.supabase.co",
  anonKey:"YOUR-PUBLISHABLE-OR-ANON-KEY"
};
```

6. Commit the edited config file. GitHub Pages will publish multiplayer with the rest of the site.

The publishable/anon key is designed to be public in a browser app. Never put the Supabase service-role key in this repository.

## Updating the song catalog

When `songs.js` changes, regenerate `supabase/seed-songs.sql` from the same ordered catalog and run it in the SQL editor. The numeric song IDs must stay aligned between the browser catalog and the database.

## Multiplayer rules

- Versus supports one round, best of three, and best of five.
- Both players receive the same server-selected song and have six guesses.
- Opponents see progress but not song names during an active round.
- Co-op requires exactly two players. Both lock a proposal before either answer is revealed.
- When proposals differ, both players must confirm the same choice before the shared guess is consumed.
