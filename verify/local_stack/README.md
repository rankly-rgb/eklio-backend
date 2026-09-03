# `verify/local_stack/`

Applies every migration and runs every test in this repo against a throwaway
local Postgres, for fast iteration without a Supabase project.

Run: `DATABASE_URL=postgresql://postgres:postgres@localhost:5432/postgres bash verify/local_stack/run.sh`
(that's the default if `DATABASE_URL` is unset — override it to point at any
admin connection you already have; `psql` is the only dependency).

**Never applied to a Supabase project.** `schema_stubs.sql` is a stand-in for
`auth`/`storage` good enough to apply and run this repo's SQL locally — it is
not real Supabase, has no PostgREST/realtime/vault, and running it against a
linked project would create tables Supabase already owns.
