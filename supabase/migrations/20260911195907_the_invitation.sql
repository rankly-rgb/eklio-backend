-- ============================================================================
-- Session 4 — the invitation
-- ============================================================================
-- ⚠ THE 2 SEPTEMBER DOCUMENT DOES NOT DESCRIBE AN INVITATIONS TABLE. It puts
-- the invitation ON the membership row:
--
--   organization_members  org_id, user_id (nullable tant que non inscrit),
--                         role, status ('invited'|'active'|'removed'),
--                         invite_token, invited_email, project_id,
--                         created_at, activated_at
--
-- Session 3 shipped that table with `user_id NOT NULL` and a primary key of
-- `(organization_id, user_id)`, because Session 3 was built from the brief and
-- the brief quoted the schema without the invitation columns. Both are
-- incompatible with an invited row, which has no user yet. This migration
-- brings the table to the decision of record.
--
-- ── THE ONE PLACE THIS DELIBERATELY DIVERGES FROM THE DOCUMENT ──────────────
--
-- `invite_token` becomes `invite_token_hash`. The document names the column
-- `invite_token`; the standing instruction is to reuse the anonymous-brief
-- pattern rather than invent a second one — hash stored, plaintext only in an
-- httpOnly cookie, null rather than empty string. A plaintext token at rest is
-- readable by anyone who can read the row, and the point of the pattern is
-- that the database never holds the secret.
--
-- ── SEATS, SINCE THE SHAPE MUST NOT PRECLUDE THEM ───────────────────────────
--
-- The document's reconciliation rule — "compare sièges facturés et membres
-- ACTIFS, et qui SIGNALE au lieu de corriger" — settles it: a seat follows an
-- ACTIVE member. An invitation is `status = 'invited'`, which is not active and
-- therefore not billed. A practice that invites eight and sees three accept is
-- billed for three, and there is nothing to game because an unaccepted
-- invitation grants nothing.
--
-- ⚠ SO THE SEAT COUNT IS DERIVED, NEVER STORED, and no column here holds one.
-- Per-seat billing is explicitly not October; what this migration owes it is a
-- `status` that makes the count answerable later without another migration,
-- and the note that the Stripe quantity sync fires on ACTIVATION, not on
-- invitation — "un membre ajouté" must mean one who became active, or the
-- reconciliation would flag every outstanding invitation as drift by
-- construction.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The membership row learns to hold an invitation
-- ---------------------------------------------------------------------------
alter table public.organization_members
  add column if not exists id uuid not null default gen_random_uuid();

alter table public.organization_members drop constraint if exists organization_members_pkey;
alter table public.organization_members add constraint organization_members_pkey primary key (id);

-- ⚠ NULLABLE NOW, AND THAT IS THE WHOLE FEATURE. An invited clinician has no
-- account yet; the row exists so that the practice can see the invitation, and
-- so that accepting it is an UPDATE of something that already exists rather
-- than an INSERT a stranger would have to be authorised to make.
alter table public.organization_members alter column user_id drop not null;

alter table public.organization_members
  add column if not exists status text not null default 'active',
  add column if not exists invited_email text,
  add column if not exists invite_token_hash text,
  add column if not exists invite_expires_at timestamptz,
  add column if not exists activated_at timestamptz,
  /*
   * The clinician's own brand project inside the practice. ON DELETE SET NULL
   * on purpose, and it is NOT the mistake `purchases_project_id_fkey` makes:
   * there, a detached purchase still claimed to be paid for something. Here
   * null means "this member has no brand project", which is exactly true both
   * before one is made and after one is deleted. Losing a project must not
   * remove the person from the practice.
   */
  add column if not exists project_id uuid references public.projects(id) on delete set null;

-- Existing rows are all real, accepted owners.
update public.organization_members
   set status = 'active', activated_at = coalesce(activated_at, created_at)
 where status is distinct from 'active' or activated_at is null;

/*
 * ⚠ AND `handle_new_user` HAD TO LEARN IT TOO. The shape check below refused
 * the first signup of the dry run: the trigger wrote an active membership with
 * a null `activated_at`, because until this migration there was no such column
 * and nothing to fill. Caught by the constraint rather than by review, which
 * is the argument for writing the constraint.
 */
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org_id uuid;
begin
  insert into public.profiles (id, email)
  values (new.id, new.email);

  insert into public.organizations default values
  returning id into v_org_id;

  insert into public.organization_members
    (organization_id, user_id, role, status, activated_at)
  values (v_org_id, new.id, 'owner', 'active', now());

  return new;
end;
$function$;

alter table public.organization_members drop constraint if exists organization_members_status_check;
alter table public.organization_members add constraint organization_members_status_check
  check (status in ('invited', 'active', 'removed'));

/*
 * ⚠ EACH STATE WITH THE COLUMNS IT REQUIRES. Without these a row can be
 * 'active' with no user, or 'invited' with no token — states that read as
 * valid and mean nothing, which is this codebase's characteristic failure.
 */
alter table public.organization_members drop constraint if exists organization_members_invited_shape_check;
alter table public.organization_members add constraint organization_members_invited_shape_check
  check (status <> 'invited' or (
    user_id is null
    and invited_email is not null
    and invite_token_hash is not null
    and invite_expires_at is not null));

alter table public.organization_members drop constraint if exists organization_members_active_shape_check;
alter table public.organization_members add constraint organization_members_active_shape_check
  check (status <> 'active' or (user_id is not null and activated_at is not null));

-- One membership row per person per practice — among rows that name a person.
drop index if exists organization_members_one_row_per_member;
create unique index organization_members_one_row_per_member
    on public.organization_members (organization_id, user_id)
 where user_id is not null;

-- ⚠ A SPENT OR REVOKED TOKEN IS NULL, NEVER ''. Null does not collide in a
-- unique index and matches nothing; '' collides with every other ''.
drop index if exists organization_members_invite_token_hash_key;
create unique index organization_members_invite_token_hash_key
    on public.organization_members (invite_token_hash)
 where invite_token_hash is not null;

-- ⚠ THE OWNER INDEX NOW EXCLUDES NON-ACTIVE ROWS. Without `status = 'active'`
-- a removed owner would block the same person from owning anywhere else.
drop index if exists organization_members_one_owned_org_per_user;
create unique index organization_members_one_owned_org_per_user
    on public.organization_members (user_id)
 where role = 'owner' and status = 'active';

create index if not exists organization_members_invited_email_idx
    on public.organization_members (organization_id, invited_email)
 where status = 'invited';

comment on column public.organization_members.status is
  'invited (no account yet, holds a token), active (a person with access), removed. A seat follows an ACTIVE member; an invitation is not billed.';
comment on column public.organization_members.invite_token_hash is
  'sha256 hex of the invitation token. The plaintext exists only in the emailed link and an httpOnly cookie, never here. Null once spent or revoked — never the empty string.';

-- ---------------------------------------------------------------------------
-- 2. ⚠ ACCESS FOLLOWS status = 'active', AND ONLY THAT
-- ---------------------------------------------------------------------------
-- Session 3's `is_org_member` asked only whether a row existed. From this
-- migration a row also exists for people who have been INVITED and for people
-- who have been REMOVED. Leaving it as it was would hand a removed clinician
-- continuing access to the practice, silently — the single most expensive
-- thing this table could get wrong.
CREATE OR REPLACE FUNCTION public.is_org_member(p_org_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_org_id is not null
     and exists (
       select 1
         from public.organization_members m
        where m.organization_id = p_org_id
          and m.user_id = (select auth.uid())
          and m.status = 'active'
     );
$function$;

-- Same reason: the claim must bind a project to the practice its owner is
-- ACTIVE in, not one they were invited to or removed from.
CREATE OR REPLACE FUNCTION public.projects_bind_organization()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_org uuid;
begin
  if tg_op = 'UPDATE'
     and new.user_id is not distinct from old.user_id
     and new.organization_id is not distinct from old.organization_id then
    return new;
  end if;

  if new.user_id is null then
    new.organization_id := null;
    return new;
  end if;

  if new.organization_id is not null
     and (public.caller_is_the_database() or auth.role() = 'service_role') then
    return new;
  end if;

  select m.organization_id into v_org
    from public.organization_members m
   where m.user_id = new.user_id
     and m.role = 'owner'
     and m.status = 'active';

  if v_org is null then
    raise exception 'project % has an owner (%) with no owning organization', new.id, new.user_id
      using errcode = 'foreign_key_violation';
  end if;

  new.organization_id := v_org;
  return new;
end
$function$;

revoke execute on function public.projects_bind_organization() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Minting an invitation
-- ---------------------------------------------------------------------------
/*
 * ⚠ RETURNS THE PLAINTEXT ONCE AND NEVER AGAIN. The row keeps only the hash,
 * so a lost invitation is re-sent by re-inviting, not by reading the token
 * back. That is the same bargain the anonymous brief makes.
 *
 * WHO CALLS IT, AND WITH WHAT IDENTITY: an owner from the browser
 * (`authenticated`, gated in-body on being an ACTIVE owner of that practice),
 * the server, or the database. Never `anon` — no anonymous act should create a
 * membership row.
 */
CREATE OR REPLACE FUNCTION public.invite_clinician(p_organization_id uuid, p_email text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_token text;
begin
  if p_organization_id is null or v_email = '' or position('@' in v_email) = 0 then
    raise exception 'invite_clinician: an organization and an email address are required.'
      using errcode = 'invalid_parameter_value';
  end if;

  if not (public.caller_is_the_database()
          or auth.role() = 'service_role'
          or exists (select 1 from public.organization_members m
                      where m.organization_id = p_organization_id
                        and m.user_id = (select auth.uid())
                        and m.role = 'owner'
                        and m.status = 'active')) then
    -- Same shape as every other refusal here: it does not confirm that the
    -- organization exists.
    raise exception 'invite_clinician: not your practice.' using errcode = 'insufficient_privilege';
  end if;

  if exists (select 1 from public.organization_members m
              join public.profiles p on p.id = m.user_id
             where m.organization_id = p_organization_id
               and lower(p.email) = v_email
               and m.status = 'active') then
    raise exception 'invite_clinician: % is already in this practice.', v_email
      using errcode = 'unique_violation';
  end if;

  -- Re-inviting the same address replaces the outstanding invitation rather
  -- than accumulating rows that all open the same door.
  update public.organization_members
     set status = 'removed', invite_token_hash = null, invite_expires_at = null
   where organization_id = p_organization_id
     and status = 'invited'
     and invited_email = v_email;

  -- 32 random bytes, base64url, 43 characters — the same shape and the same
  -- entropy as the anonymous brief token.
  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');

  insert into public.organization_members
    (organization_id, user_id, role, status, invited_email, invite_token_hash, invite_expires_at)
  values
    (p_organization_id, null, 'clinician', 'invited', v_email,
     encode(extensions.digest(v_token, 'sha256'), 'hex'),
     now() + make_interval(days => 14));

  return v_token;
end
$function$;

revoke execute on function public.invite_clinician(uuid, text) from public, anon;
grant execute on function public.invite_clinician(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. What she sees before she has an account
-- ---------------------------------------------------------------------------
/*
 * ⚠ THE DOCUMENT'S REQUIREMENT: « le clinicien reçoit un lien à jeton et doit
 * voir sa page AVANT de créer un compte. » A token does not pass through
 * `auth.uid()`, so this is a SECURITY DEFINER RPC taking the token as an
 * ARGUMENT — never a permissive RLS policy making invited rows readable. The
 * document names that as the exact trap.
 *
 * It returns the practice and who invited her, and nothing else. Not the
 * roster, not the other invitations, not a project. An invalid, expired or
 * spent token returns NULL — the same answer for all three, because telling
 * them apart tells a stranger which tokens exist.
 */
CREATE OR REPLACE FUNCTION public.organization_invitation_preview(p_token text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
           'organization_id', o.id,
           'practice_name',   o.name,
           'invited_email',   m.invited_email,
           'invited_by',      (select p.full_name
                                 from public.organization_members om
                                 join public.profiles p on p.id = om.user_id
                                where om.organization_id = o.id
                                  and om.role = 'owner'
                                  and om.status = 'active'
                                limit 1),
           'expires_at',      m.invite_expires_at)
    from public.organization_members m
    join public.organizations o on o.id = m.organization_id
   where m.status = 'invited'
     and m.invite_expires_at > now()
     and p_token is not null
     and length(p_token) between 20 and 200
     and m.invite_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
   limit 1;
$function$;

revoke execute on function public.organization_invitation_preview(text) from public;
grant execute on function public.organization_invitation_preview(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Accepting it
-- ---------------------------------------------------------------------------
/*
 * ⚠ VERIFY-THEN-CONSUME IN ONE STATEMENT, this repository's rule for anything
 * single-use. The WHERE clause is the verification; there is no read followed
 * by a write for two requests to interleave between.
 *
 * The token is spent by being set to NULL rather than '' — null collides with
 * nothing and matches nothing, and the unique index is partial on
 * `is not null` so spent rows do not fight each other.
 */
CREATE OR REPLACE FUNCTION public.accept_organization_invitation(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_org uuid;
begin
  if v_uid is null then
    -- She must have an account by now: accepting IS attaching an account to
    -- the invitation.
    return jsonb_build_object('accepted', false, 'reason', 'no_session');
  end if;
  if p_token is null or length(p_token) not between 20 and 200 then
    return jsonb_build_object('accepted', false, 'reason', 'no_token');
  end if;

  update public.organization_members m
     set user_id           = v_uid,
         status            = 'active',
         activated_at      = now(),
         invite_token_hash = null,
         invite_expires_at = null
   where m.status = 'invited'
     and m.invite_expires_at > now()
     and m.invite_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
     -- ⚠ AND SHE IS NOT ALREADY IN THIS PRACTICE, or the unique index would
     -- raise where a plain answer is wanted.
     and not exists (select 1 from public.organization_members other
                      where other.organization_id = m.organization_id
                        and other.user_id = v_uid)
  returning m.organization_id into v_org;

  if v_org is null then
    -- Expired, already spent, never existed, or she is already a member. One
    -- answer for all of them.
    return jsonb_build_object('accepted', false, 'reason', 'not_open');
  end if;

  return jsonb_build_object('accepted', true, 'organization_id', v_org);
end
$function$;

revoke execute on function public.accept_organization_invitation(text) from public, anon;
grant execute on function public.accept_organization_invitation(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. The roster a practice can read
-- ---------------------------------------------------------------------------
-- Session 3's SELECT policy said `is_org_member(organization_id)`, which now
-- means active members only — correct for who may look. What they see has to
-- include the invited rows, or an owner cannot see their own outstanding
-- invitations. The token hash is not protected by being hidden; it is
-- protected by being a hash.
drop policy if exists organization_members_select_member on public.organization_members;
create policy organization_members_select_member on public.organization_members
  for select to authenticated
  using (public.is_org_member(organization_id));

-- ============================================================================
-- Guard rails — the whole walk, in one transaction
-- ============================================================================
do $$
declare
  v_owner uuid := gen_random_uuid();
  v_strng uuid := gen_random_uuid();
  v_clin  uuid := gen_random_uuid();
  v_org   uuid;
  v_token text;
  v_res   jsonb;
begin
  insert into auth.users (id, email) values
    (v_owner, 'guard-owner-'    || v_owner || '@example.invalid'),
    (v_strng, 'guard-stranger-' || v_strng || '@example.invalid'),
    (v_clin,  'guard-clin-'     || v_clin  || '@example.invalid');
  select organization_id into v_org from public.organization_members
   where user_id = v_owner and role = 'owner';

  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', v_owner)::text, true);
  perform set_config('request.headers', '{}', true);
  v_token := public.invite_clinician(v_org, 'guard.clinician@example.invalid');

  assert length(v_token) = 43, format('the token is %s characters, not 43', length(v_token));
  assert not exists (select 1 from public.organization_members where invite_token_hash = v_token),
    '⚠ THE PLAINTEXT TOKEN IS IN THE TABLE';

  -- A stranger cannot invite into a practice that is not theirs.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', v_strng)::text, true);
  begin
    perform public.invite_clinician(v_org, 'sneak@example.invalid');
    assert false, '⚠ A STRANGER INVITED INTO SOMEONE ELSE''S PRACTICE';
  exception when insufficient_privilege then null;
  end;

  -- She can read her page before she has an account, and a wrong token reads
  -- as nothing rather than as an error.
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  assert public.organization_invitation_preview(v_token) is not null,
    'the invited clinician cannot see her page before signing up';
  assert public.organization_invitation_preview(repeat('z', 43)) is null,
    'a wrong token was previewed';

  -- An invitation is not membership.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', v_clin)::text, true);
  assert public.is_org_member(v_org) is false,
    '⚠ AN INVITED PERSON ALREADY HAS ACCESS';

  v_res := public.accept_organization_invitation(v_token);
  assert (v_res ->> 'accepted')::boolean, format('accepting failed: %s', v_res);
  assert public.is_org_member(v_org) is true, 'accepting did not grant access';

  -- Single use.
  v_res := public.accept_organization_invitation(v_token);
  assert (v_res ->> 'accepted')::boolean is false, format('the token was spent twice: %s', v_res);

  -- Removal takes access away.
  perform set_config('request.jwt.claims', '', true);
  update public.organization_members set status = 'removed'
   where user_id = v_clin and organization_id = v_org;
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', v_clin)::text, true);
  assert public.is_org_member(v_org) is false,
    '⚠ A REMOVED CLINICIAN STILL HAS ACCESS TO THE PRACTICE';

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);

  assert not exists (select 1 from public.organization_members where invite_token_hash = ''),
    'a spent token was written as the empty string rather than null';

  -- Clean up: three users, and their organizations, which do not cascade.
  delete from auth.users where id in (v_owner, v_strng, v_clin);
  delete from public.organizations o
   where not exists (select 1 from public.organization_members m where m.organization_id = o.id)
     and not exists (select 1 from public.projects p where p.organization_id = o.id);
  assert not exists (select 1 from public.profiles where id in (v_owner, v_strng, v_clin)),
    'the guard rail left its fixture accounts behind';
end
$$;
