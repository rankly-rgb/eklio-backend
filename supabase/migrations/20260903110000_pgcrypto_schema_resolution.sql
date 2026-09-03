-- ============================================================================
-- Eklio — tenancy layer, lot A1: pgcrypto schema resolution
-- ============================================================================
-- 20260903102500_org_invite_rpcs.sql hard-coded `extensions.gen_random_bytes`
-- and `extensions.digest`, flagged there as an assumption this session could
-- not verify against the real project (pgcrypto may live in `public` there
-- instead). Rather than guessing again, these two helpers resolve pgcrypto's
-- installed schema from the catalog at call time and dispatch through
-- `execute format(...)` — correct on either layout, with `search_path = ''`
-- intact (dynamic SQL with a quoted identifier, not a widened search_path).
--
-- `create extension if not exists pgcrypto` already runs in
-- 20260903102500_org_invite_rpcs.sql — not repeated here.
-- ============================================================================

create or replace function public.random_token_hex(p_bytes int)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_schema text;
  v_result text;
begin
  select n.nspname into v_schema
    from pg_extension e
    join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';

  if v_schema is null then
    raise exception 'random_token_hex: pgcrypto extension is not installed';
  end if;

  execute format('select encode(%I.gen_random_bytes($1), $2)', v_schema)
    into v_result
    using p_bytes, 'hex';

  return v_result;
end;
$$;

comment on function public.random_token_hex(int) is
  'p_bytes random bytes from pgcrypto''s gen_random_bytes, hex-encoded. Resolves pgcrypto''s schema from pg_extension at call time rather than assuming extensions or public. Internal only — see the grants below.';

create or replace function public.sha256_hex(p_text text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_schema text;
  v_result text;
begin
  select n.nspname into v_schema
    from pg_extension e
    join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';

  if v_schema is null then
    raise exception 'sha256_hex: pgcrypto extension is not installed';
  end if;

  execute format('select encode(%I.digest($1, $2), $3)', v_schema)
    into v_result
    using p_text, 'sha256', 'hex';

  return v_result;
end;
$$;

comment on function public.sha256_hex(text) is
  'sha256(p_text), hex-encoded. Resolves pgcrypto''s schema from pg_extension at call time. Internal only — see the grants below.';

-- Both are called only from inside other SECURITY DEFINER functions
-- (create_org_invite, preview_org_invite, accept_org_invite, below), which
-- run as their owner — an internal call needs no separate EXECUTE grant.
-- No client role, including authenticated, calls either directly: the
-- minimum grant is none.
revoke execute on function public.random_token_hex(int) from public, anon, authenticated;
revoke execute on function public.sha256_hex(text)      from public, anon, authenticated;


-- ============================================================================
-- The three invite RPCs that used the hard-coded schema, now using the
-- helpers above. Same signatures, same grants, same behavior — only the
-- token's own encoding changes (hex instead of base64url; still URL-safe,
-- simpler to derive). Existing invite rows are unaffected: their stored
-- invite_token_hash is just a hex hash regardless of what encoding the raw
-- token that produced it used.
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

  v_raw_token  := public.random_token_hex(32);
  v_token_hash := public.sha256_hex(v_raw_token);

  insert into public.organization_members
    (organization_id, user_id, role, status, invited_email, invite_token_hash, project_id)
  values
    (p_org_id, null, 'clinician', 'invited', v_email, v_token_hash, p_project_id);

  return v_raw_token;
end;
$$;

revoke execute on function public.create_org_invite(uuid, citext, uuid) from public, anon, authenticated;
grant  execute on function public.create_org_invite(uuid, citext, uuid) to authenticated;

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

  v_hash := public.sha256_hex(p_token);

  return query
    select o.name, m.invited_email
      from public.organization_members m
      join public.organizations o on o.id = m.organization_id
     where m.invite_token_hash = v_hash
       and m.status = 'invited';
end;
$$;

revoke execute on function public.preview_org_invite(text) from public;
grant  execute on function public.preview_org_invite(text) to anon, authenticated;

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
  v_invited    text;
  v_user_email text;
begin
  if auth.uid() is null then
    raise exception 'accept_org_invite: no authenticated user';
  end if;

  v_hash := public.sha256_hex(p_token);

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

revoke execute on function public.accept_org_invite(text) from public, anon, authenticated;
grant  execute on function public.accept_org_invite(text) to authenticated;
