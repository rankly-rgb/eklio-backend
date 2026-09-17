create table if not exists public.ethics_patterns (
  id               text        not null,
  rule_id          text        not null,
  pattern          text        not null,
  exception_pattern text,
  severity         text        not null,
  sort_order       smallint    not null,
  active           boolean     not null default true,
  constraint ethics_patterns_pkey primary key (id),
  constraint ethics_patterns_rule_fkey foreign key (rule_id) references public.ethics_rules (id),
  constraint ethics_patterns_severity_check check (severity = any (array['block', 'warn'])),
  constraint ethics_patterns_pattern_check  check (btrim(pattern) <> ''),
  constraint ethics_patterns_exception_check
    check (exception_pattern is null or btrim(exception_pattern) <> '')
);

comment on table public.ethics_patterns is
  'The deterministic advertising-ethics patterns, as DATA. They lived only in TypeScript, where no SQL function can read them - and a scan that runs only in the application does not cover text written straight through a RPC. Sibling of ethics_rules (the six rules in words) and banned_phrases (thirty literal formulations).';
comment on column public.ethics_patterns.exception_pattern is
  'Postgres has no negative lookahead. A pattern that needs one carries its exception here instead of losing it, which would turn a legitimate sentence into a refused write.';

alter table public.ethics_patterns enable row level security;
drop policy if exists ethics_patterns_select_all on public.ethics_patterns;
create policy ethics_patterns_select_all on public.ethics_patterns
  for select to anon, authenticated using (true);
drop policy if exists ethics_patterns_write_denied on public.ethics_patterns;
create policy ethics_patterns_write_denied on public.ethics_patterns
  for all using (false) with check (false);

grant select on public.ethics_patterns to anon, authenticated;

-- >>> ETHICS PATTERN DATA (mirrored verbatim in supabase/seed.sql) >>>
insert into public.ethics_patterns (id, rule_id, pattern, exception_pattern, severity, sort_order) values
  ('resolution_verb', 'proven',
   '\y(heal|heals|healed|healing|cure|cures|cured|curing|fix|fixes|fixed|fixing|eliminate|eliminates|eliminated|eliminating|erase|erases|erasing|end|ends|ending|resolve|resolves|resolved|resolving|overcome|overcomes|overcoming|banish|banishes|banishing|remove|removes|removing|conquer|conquers|conquering|defeat|defeats)\y( +\w+){0,3} +\y(anxiety|anxieties|depression|trauma|traumas|ptsd|panic +attacks?|panic|ocd|grief|addiction|addictions|burnout|stress|insomnia|adhd|phobias?|shame|codependency|overwhelm)\y',
   null, 'block', 1),
  ('free_you_from', 'proven',
   '\y(free +you +from|rid +you +of|get +rid +of|take +away +your|make +(it|your +\w+) +go +away)\y',
   null, 'block', 2),
  ('is_gone', 'proven',
   '\y(anxiety|anxieties|depression|trauma|traumas|ptsd|panic +attacks?|panic|ocd|grief|addiction|addictions|burnout|stress|insomnia|adhd|phobias?|shame|codependency|overwhelm)\y[^.!?]{0,30}\y(is|are|will +be|''?ll +be) +(gone|behind +you|history|a +thing +of +the +past|no +longer +(a +problem|an +issue))\y',
   null, 'block', 3),
  ('dated_promise', 'timeframe',
   '\y(results?|relief|change|changes|healing|progress|improvement|breakthrough|transformation|better)\y[^.!?]{0,40}\yin +(as +little +as +|just +|only +)?[0-9]+ *(days?|weeks?|months?|sessions?)\y',
   null, 'block', 4),
  ('guarantee', 'proven', '\yguarantee(s|d|ing)?\y', null, 'block', 5),
  ('clinically_proven', 'proven',
   '\y(clinically|scientifically|medically|statistically) +proven\y|\yproven +(to\y|results?\y|method|approach|system|technique|protocol|track +record)',
   null, 'block', 6),
  ('success_rate', 'proven',
   '\y([0-9]{1,3} *(%|percent)|[0-9]+ +out +of +[0-9]+|nine +out +of +ten) +(of +)?(my|our|her|his|their)? *(clients?|patients?)\y|\ysuccess +rate\y',
   null, 'block', 7),
  ('lasting_relief', 'proven',
   '\y(lasting|permanent|life-?long|complete|full) +(relief|results?|recovery|healing|peace|calm|freedom)\y',
   null, 'block', 8),
  ('therapy_that_works', 'proven',
   '\y(treatment|therapy|approach|method) +that +(actually +|really +)?(works|will +work)\y',
   '\y(treatment|therapy|approach|method) +that +(actually +|really +)?(works|will +work) +(best +)?for +you\y',
   'block', 9),
  ('testimonial_word', 'client_voice', '\ytestimonials?\y', null, 'block', 10),
  ('clients_say', 'client_voice',
   '\y((my|our|her|his|their) +)?(clients?|patients?) +(often|frequently|sometimes|usually|always|regularly|routinely|consistently)? *(say|says|said|report|reports|reported|tell|tells|told|describe|describes|rave|love|feel|feels|felt)\y',
   null, 'block', 11),
  ('client_reviews', 'client_voice',
   '\yclient +(reviews?|feedback|ratings?)\y|\ypatient +reviews?\y|\y(reviewed|rated|recommended) +by +(my|our|former|past|hundreds +of|[0-9]+) *(clients?|patients?)\y',
   null, 'block', 12),
  ('star_rating', 'client_voice',
   '\yfive[- ]star\y|\y[0-9](\.[0-9])? *(/ *5|out +of +5) *stars?\y|[★⭐]',
   null, 'block', 13),
  ('success_story', 'client_voice',
   '\y(success|client|patient) +stor(y|ies)\y', null, 'block', 14),
  ('best_therapist', 'scarcity',
   '(\y(best|top|leading|premier|foremost|most +trusted|top-?rated|number +one)|# *1) +(\w+ +){0,2}(therapist|therapists|counselor|counselors|counsellor|psychologist|psychologists|clinician|clinicians|clinic|provider|providers|coach|therapy)\y',
   null, 'block', 15),
  ('award_winning', 'credential',
   '\y(award-?winning|nationally +recognized|world-?class|world-?renowned|renowned)\y',
   null, 'warn', 16),
  ('weekend_certification', 'credential',
   '\y(weekend|two-?day|one-?day|[0-9]+-?(day|hour)) +(certification|certificate|certified|intensive)\y|\ycertified\y[^.!?]{0,40}\y(weekend|workshop|webinar|ce +course|short +course)\y',
   null, 'block', 17),
  ('you_have_condition', 'diagnosis',
   '\yyou +(have|clearly +have|probably +have|likely +have|are +suffering +from|suffer +from) +(\w+ +){0,2}\y(anxiety|anxieties|depression|trauma|traumas|ptsd|panic +attacks?|panic|ocd|grief|addiction|addictions|burnout|stress|insomnia|adhd|phobias?|shame|codependency|overwhelm)\y',
   null, 'block', 18),
  ('scarcity_urgency', 'scarcity',
   '\yonly +[0-9]+ +(spots?|slots?|places?|openings?) +(left|remaining|available)\y|\ylimited +(spots?|slots?|places?|openings?|availability|space)\y|\y(spots?|slots?|places?|openings?) +(are +)?(limited|filling +up)\y|\ylimited[- ]time +offer\y|\yact +now\y|\ydon''?t +wait\y|\ylast +chance\y|\ybook +(now +)?before +(prices|rates|spots)\y',
   null, 'block', 19)
on conflict (id) do update set
  rule_id = excluded.rule_id, pattern = excluded.pattern,
  exception_pattern = excluded.exception_pattern,
  severity = excluded.severity, sort_order = excluded.sort_order;
-- <<< ETHICS PATTERN DATA <<<

create or replace function public.ethics_scan(p_text text)
returns jsonb
language sql
stable
set search_path to ''
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'rule_id',  ep.rule_id,
      'severity', ep.severity,
      'excerpt',  coalesce(substring(p_text from '(?i)(' || ep.pattern || ')'), '(match)')
    ) order by ep.sort_order),
    '[]'::jsonb)
    from public.ethics_patterns ep
   where ep.active
     and p_text is not null
     and p_text ~* ep.pattern
     and not coalesce(p_text ~* ep.exception_pattern, false)
$$;

comment on function public.ethics_scan(text) is
  'The deterministic advertising-ethics scan, in the database, so that text written straight through a RPC is covered too. Returns every match with its rule and the offending excerpt. Does NOT rewrite: enforceEthics in the application asks the model to fix the field, a write constraint can only refuse - which is the right split, since the practitioner corrects her own words herself.';

revoke all on function public.ethics_scan(text) from public;
grant execute on function public.ethics_scan(text) to anon, authenticated, service_role;

create or replace function public.ethics_blocks(p_text text)
returns text
language sql
stable
set search_path to ''
as $$
  select coalesce(nullif(v ->> 'excerpt', ''), v ->> 'rule_id', 'blocked')
    from jsonb_array_elements(public.ethics_scan(p_text)) as e(v)
   where v ->> 'severity' = 'block'
   limit 1
$$;

comment on function public.ethics_blocks(text) is
  'The first blocking excerpt in a piece of text, or NULL. Separate from ethics_scan so a trigger reads one value: a WARN is logged by the application, a BLOCK refuses a write.';

revoke all on function public.ethics_blocks(text) from public;
grant execute on function public.ethics_blocks(text) to anon, authenticated, service_role;

create or replace function public.site_specs_ethics_gate()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_block text;
  v_text  text;
begin
  for v_text in
    select expanded.leaf #>> '{}'
      from jsonb_array_elements(coalesce(new.pages, '[]'::jsonb))          as page,
           jsonb_array_elements(coalesce(page.value -> 'sections', '[]'::jsonb)) as section,
           jsonb_each(coalesce(section.value -> 'fields', '{}'::jsonb))    as field(fkey, fvalue),
           jsonb_array_elements(
             case when jsonb_typeof(field.fvalue) = 'array'
                  then field.fvalue
                  else jsonb_build_array(field.fvalue)
             end
           ) as expanded(leaf)
     where jsonb_typeof(expanded.leaf) = 'string'
    union all
    select value from jsonb_each_text(coalesce(new.hero, '{}'::jsonb))
    union all
    select new.about_excerpt
    union all
    select new.extra_instructions
  loop
    v_block := public.ethics_blocks(v_text);
    if v_block is not null then
      raise exception
        'Advertising ethics: %', v_block
        using errcode = 'check_violation',
              hint = 'That phrasing can put a licence at risk. Rewrite it as a description of the work.';
    end if;
  end loop;

  return new;
end
$$;

revoke all on function public.site_specs_ethics_gate() from public, anon, authenticated;

drop trigger if exists site_specs_ethics_gate on public.site_specs;
create trigger site_specs_ethics_gate
  before insert or update on public.site_specs
  for each row execute function public.site_specs_ethics_gate();

create or replace function public.content_items_ethics_gate()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_block text;
  v_text  text;
begin
  foreach v_text in array array[new.title, new.caption, new.on_image_text, new.alt_text]
  loop
    v_block := public.ethics_blocks(v_text);
    if v_block is not null then
      raise exception
        'Advertising ethics: %', v_block
        using errcode = 'check_violation',
              hint = 'That phrasing can put a licence at risk. Rewrite it as a description of the work.';
    end if;
  end loop;

  return new;
end
$$;

revoke all on function public.content_items_ethics_gate() from public, anon, authenticated;

drop trigger if exists content_items_ethics_gate on public.content_items;
create trigger content_items_ethics_gate
  before insert or update on public.content_items
  for each row execute function public.content_items_ethics_gate();

create or replace function public.directory_profiles_ethics_gate()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_block text;
  v_cliches text[];
  v_text  text;
begin
  foreach v_text in array array[new.first_paragraph, new.body]
  loop
    v_block := public.ethics_blocks(v_text);
    if v_block is not null then
      raise exception 'Advertising ethics: %', v_block
        using errcode = 'check_violation',
              hint = 'That phrasing can put a licence at risk. Rewrite it as a description of the work.';
    end if;

    v_cliches := public.usp_banned_phrases_check(v_text);
    if coalesce(array_length(v_cliches, 1), 0) > 0 then
      raise exception
        'Directory cliche: %', array_to_string(v_cliches, ', ')
        using errcode = 'check_violation',
              hint = 'Every profile in the state says this. Say what she actually does instead.';
    end if;
  end loop;

  return new;
end
$$;

revoke all on function public.directory_profiles_ethics_gate() from public, anon, authenticated;

drop trigger if exists directory_profiles_ethics_gate on public.directory_profiles;
create trigger directory_profiles_ethics_gate
  before insert or update on public.directory_profiles
  for each row execute function public.directory_profiles_ethics_gate();

revoke execute on function public.create_content_item(uuid, text, date) from public, anon;
revoke execute on function public.update_content_item(uuid, jsonb)      from public, anon;
revoke execute on function public.delete_content_item(uuid)             from public, anon;
revoke execute on function public.site_spec_patch(uuid, jsonb)          from public, anon;
revoke execute on function public.get_publishing_log(uuid, integer)     from public, anon;

grant execute on function public.create_content_item(uuid, text, date) to authenticated, service_role;
grant execute on function public.update_content_item(uuid, jsonb)      to authenticated, service_role;
grant execute on function public.delete_content_item(uuid)             to authenticated, service_role;
grant execute on function public.site_spec_patch(uuid, jsonb)          to authenticated, service_role;
grant execute on function public.get_publishing_log(uuid, integer)     to authenticated, service_role;
