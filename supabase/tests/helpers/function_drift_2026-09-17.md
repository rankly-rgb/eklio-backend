# The forty-one function definitions that differ from a replay

Recorded 17 September 2026, against project `fobgdsupyfslxbswfuay`.

After the eleven migrations of 14 September were recovered and the six of
15 September renamed, a full replay of `supabase/migrations` matches production
on **every object but these**: 2504 objects, 0 only in production, 0 only in the
replay, 41 different, all of kind `function`. Their `function.body` rows — the
whole kind, all 258 — match production exactly.

## Why this file exists rather than a sentence saying "only comments"

`schema_fingerprint.sql` normalises a body with three `regexp_replace` calls and
says, in its own header, that the normalisation is approximate **in the unsafe
direction**: it strips `--` and `/* */` without knowing whether they sit inside a
string literal, so it may make two different definitions compare *equal*. It
forbids using that result to dismiss a difference.

So "only a comment" was a guess. `scripts/sql_tokens.py` turns it into a
decision: a real PostgreSQL lexer — line comments, nested block comments, `''`
and `E'\'` escapes, dollar quotes with arbitrary tags, quoted identifiers — that
drops comments and keeps **every literal verbatim**, and which opens exactly one
dollar-quoted run, the function body the top-level `AS` introduces. Its sixteen
probes include the three cases the regex gets wrong; `--self-test` runs them and
`scripts/local-verify.sh` runs `--self-test`.

Three verdicts were allowed and no fourth: **identical**, **comment gap, proven**,
**behaviour differs**.

| result | count |
|---|---|
| identical | 0 |
| comment gap, proven | 41 |
| behaviour differs | 0 |

## What the difference actually is

Production holds these functions **with their comments removed**. The replay
holds them as the migration files were written, prose included. The direction is
the same in all 41: the repository is the longer side. Whatever applied them
stripped the commentary on the way in, which is why the previous snapshot of
12 September already carried thirty-eight of them and why nothing behavioural
was ever at stake.

It is still a divergence worth keeping visible: read production, and these
functions no longer tell you why they are what they are. Rewriting them to
restore the prose would be forty-one `create or replace` statements for no
behavioural change, on paid, working code — not obviously worth it, and not a
decision this file makes.

| function | verdict | tokens | lines the repo has more |
|---|---|---|---|
| `brand_images_claim` | comment gap, proven | 652 | +9 |
| `brand_images_enabled` | comment gap, proven | 45 | +3 |
| `brand_images_mark_failed` | comment gap, proven | 243 | +3 |
| `brand_images_mark_ready` | comment gap, proven | 307 | +3 |
| `brand_kit_entitled` | comment gap, proven | 128 | +4 |
| `brand_kit_has_generation_credit` | comment gap, proven | 158 | +3 |
| `consume_check_rewrite` | comment gap, proven | 252 | +6 |
| `consume_generation_credit` | comment gap, proven | 306 | +4 |
| `direction_assets_claim` | comment gap, proven | 464 | +-14 |
| `direction_limits` | comment gap, proven | 266 | +4 |
| `enforce_direction_selection_entitlement` | comment gap, proven | 98 | +5 |
| `get_brand_asset_manifest` | comment gap, proven | 276 | +6 |
| `get_brand_images` | comment gap, proven | 157 | +2 |
| `maintain_site_spec_text_variants` | comment gap, proven | 276 | +3 |
| `nearest_color_name` | comment gap, proven | 197 | +5 |
| `purchase_status_events_apply` | comment gap, proven | 57 | +3 |
| `section_type_fields_valid` | comment gap, proven | 201 | +7 |
| `seed_launch_checklist` | comment gap, proven | 226 | +4 |
| `set_launch_step` | comment gap, proven | 258 | +4 |
| `site_catalog` | comment gap, proven | 188 | +3 |
| `site_output_fragments` | comment gap, proven | 81 | +2 |
| `site_output_get` | comment gap, proven | 256 | +2 |
| `site_output_mark_copied` | comment gap, proven | 155 | +3 |
| `site_spec_accent_try` | comment gap, proven | 248 | +3 |
| `site_spec_copy_blocks` | comment gap, proven | 424 | +2 |
| `site_spec_credential_line` | comment gap, proven | 192 | +2 |
| `site_spec_cta_ink` | comment gap, proven | 90 | +7 |
| `site_spec_derive_accent` | comment gap, proven | 185 | +7 |
| `site_spec_fix_contrast` | comment gap, proven | 240 | +3 |
| `site_spec_hero_valid` | comment gap, proven | 119 | +3 |
| `site_spec_hue_tolerance` | comment gap, proven | 51 | +1 |
| `site_spec_identity_lines` | comment gap, proven | 315 | +2 |
| `site_spec_lab` | comment gap, proven | 461 | +2 |
| `site_spec_output_prompt` | comment gap, proven | 696 | +4 |
| `site_spec_output_setup_sheet` | comment gap, proven | 1645 | +7 |
| `site_spec_preview_model` | comment gap, proven | 358 | +2 |
| `site_spec_seed_clamped_valid` | comment gap, proven | 134 | +3 |
| `site_spec_seed_values` | comment gap, proven | 1110 | +13 |
| `site_spec_suggest_hex` | comment gap, proven | 165 | +3 |
| `site_spec_text_variant` | comment gap, proven | 66 | +5 |
| `site_spec_voice_guide` | comment gap, proven | 131 | +4 |
