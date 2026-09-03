-- ============================================================================
-- Eklio — tenancy layer, lot 1: invitation RPCs
-- ============================================================================
-- A clinician must be able to preview the invite before creating an account
-- (preview_org_invite, the one function in this whole lot open to anon), and
-- the token must never be readable through a permissive RLS policy — it never
-- touches a table a SELECT policy could expose; it is looked up only by its
-- sha256 hash, inside SECURITY DEFINER functions.
--
-- Amendment B: emails are compared against public.profiles.email, never
-- auth.users — profiles stays the one table coupled to auth in this schema.
--
-- ⚠ SCHEMA OF pgcrypto — UNVERIFIED, flagged for the human running this
-- migration. `pgcrypto` is already installed on this project (confirmed by
-- 20260901074842_usp_fingerprints.sql's header: "pgcrypto, uuid-ossp,
-- pg_stat_statements, supabase_vault are installed" as Supabase defaults),
-- but no prior migration in this repo calls gen_random_bytes/digest, so which
-- schema it lives in (commonly `extensions` on hosted Supabase, sometimes
-- `public`) has never been exercised here. Functions below are SECURITY
-- DEFINER with search_path = '', so they call `extensions.gen_random_bytes`
-- and `extensions.digest` explicitly-qualified, on that assumption. If this
-- migration fails to apply with "function extensions.gen_random_bytes(...)
-- does not exist", pgcrypto lives in a different schema on this project —
-- confirm with `select extname, extnamespace::regnamespace from pg_extension
-- where extname = 'pgcrypto';` and requalify in a new migration, per the
-- "never edit a pushed migration" rule.
create extension if not exists pgcrypto;


-- ============================================================================
-- 1. create_org_invite
-- ============================================================================

create or replace function public.create_org_invite(
  p_org_id     uuid,
  p_email      citext,
  p_project_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- `text`, not `citext`: a variable declared `citext` inside this function's
  -- body fails to resolve under `search_path = ''` — PL/pgSQL only resolves a
  -- body-local DECLARE's type name at first-call time, using the function's
  -- OWN search_path, unlike the parameter list above (resolved once, at
  -- CREATE time, under the migration's ambient search_path). Confirmed by
  -- actually applying this migration against a local Postgres — see the
  -- checkpoint report.
  v_email      text;
  v_raw_token  text;
  v_token_hash text;
begin
  if not public.is_org_owner(p_org_id) then
    raise exception 'create_org_invite: % is not an active owner of organization %', auth.uid(), p_org_id;
  end if;

  v_email := lower(btrim(p_email::text));

  if exists (
    select 1
      from public.organization_members m
      join public.profiles pr on pr.id = m.user_id
     where m.organization_id = p_org_id
       and m.status = 'active'
       and lower(pr.email) = v_email
  ) then
    raise exception 'create_org_invite: % is already an active member of this organization', v_email;
  end if;

  -- 32 random bytes, base64url (no padding) — url-safe, printable, one-shot.
  v_raw_token  := encode(extensions.gen_random_bytes(32), 'base64');
  v_raw_token  := replace(replace(replace(v_raw_token, '+', '-'), '/', '_'), '=', '');
  v_token_hash := encode(extensions.digest(v_raw_token, 'sha256'), 'hex');

  insert into public.organization_members
    (organization_id, user_id, role, status, invited_email, invite_token_hash, project_id)
  values
    (p_org_id, null, 'clinician', 'invited', v_email, v_token_hash, p_project_id);

  return v_raw_token;
end;
$$;

comment on function public.create_org_invite(uuid, citext, uuid) is
  'Owner-only. Creates an invited organization_members row and returns the raw invite token ONCE — only its sha256 hash is stored. Raises if the caller is not the active owner of p_org_id, or if p_email already belongs to an active member.';

revoke execute on function public.create_org_invite(uuid, citext, uuid) from public, anon, authenticated;
grant  execute on function public.create_org_invite(uuid, citext, uuid) to authenticated;


-- ============================================================================
-- 2. preview_org_invite — the one function in this lot open to anon
-- ============================================================================

create or replace function public.preview_org_invite(p_token text)
returns table(organization_name text, invited_email citext)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
begin
  if p_token is null or btrim(p_token) = '' then
    return;
  end if;

  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');

  return query
    select o.name, m.invited_email
      from public.organization_members m
      join public.organizations o on o.id = m.organization_id
     where m.invite_token_hash = v_hash
       and m.status = 'invited';
end;
$$;

comment on function public.preview_org_invite(text) is
  'Anon-callable. Returns one row for a valid, still-pending invite token, zero rows for anything else (unknown token, already-accepted, malformed input) — never raises, never returns an id.';

revoke execute on function public.preview_org_invite(text) from public;
grant  execute on function public.preview_org_invite(text) to anon, authenticated;


-- ============================================================================
-- 3. accept_org_invite
-- ============================================================================

create or replace function public.accept_org_invite(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash       text;
  v_member_id  uuid;
  v_org_id     uuid;
  v_invited    text;  -- text, not citext: see the note in create_org_invite above
  v_user_email text;
begin
  if auth.uid() is null then
    raise exception 'accept_org_invite: no authenticated user';
  end if;

  v_hash := encode(extensions.digest(p_token, 'sha256'), 'hex');

  select m.id, m.organization_id, m.invited_email
    into v_member_id, v_org_id, v_invited
    from public.organization_members m
   where m.invite_token_hash = v_hash
     and m.status = 'invited'
   for update;

  if not found then
    raise exception 'accept_org_invite: invalid or already-used invite token';
  end if;

  select pr.email into v_user_email
    from public.profiles pr
   where pr.id = auth.uid();

  if v_user_email is null or lower(v_user_email) <> lower(v_invited) then
    raise exception 'accept_org_invite: signed-in email does not match the invited email';
  end if;

  update public.organization_members
     set user_id           = auth.uid(),
         status             = 'active',
         activated_at       = now(),
         invite_token_hash  = null
   where id = v_member_id;

  return v_org_id;
end;
$$;

comment on function public.accept_org_invite(text) is
  'Requires an authenticated caller whose profiles.email matches (case-insensitively) the invited_email. Activates the membership and nulls the token hash, so a second call with the same raw token finds no matching row and raises. Does not create a project — that stays in the app flow.';

revoke execute on function public.accept_org_invite(text) from public, anon, authenticated;
grant  execute on function public.accept_org_invite(text) to authenticated;


-- ============================================================================
-- 4. remove_org_member
-- ============================================================================

create or replace function public.remove_org_member(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_role   text;
begin
  select m.organization_id, m.role
    into v_org_id, v_role
    from public.organization_members m
   where m.id = p_member_id;

  if not found then
    raise exception 'remove_org_member: no such member %', p_member_id;
  end if;

  if not public.is_org_owner(v_org_id) then
    raise exception 'remove_org_member: % is not an active owner of organization %', auth.uid(), v_org_id;
  end if;

  if v_role = 'owner' then
    raise exception 'remove_org_member: cannot remove an owner';
  end if;

  update public.organization_members
     set status = 'removed',
         removed_at = now()
   where id = p_member_id;
end;
$$;

comment on function public.remove_org_member(uuid) is
  'Owner-only, and refuses to remove an owner. Sets status=removed + removed_at rather than deleting the row.';

revoke execute on function public.remove_org_member(uuid) from public, anon, authenticated;
grant  execute on function public.remove_org_member(uuid) to authenticated;
