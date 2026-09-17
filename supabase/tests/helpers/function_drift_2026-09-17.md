# Les quarante-sept définitions de fonction qui diffèrent d'un rejeu

Relevé le 17 septembre 2026, contre le projet `fobgdsupyfslxbswfuay`.

Une fois les onze migrations du 14 septembre réconciliées et les six du
15 septembre renommées, un rejeu complet de `supabase/migrations` coïncide avec
la production sur **tout sauf celles-ci** : 2504 objets de chaque côté, 0 en
production seulement, 0 au rejeu seulement, 47 différentes, toutes de genre
`function`. Le genre `function.body` — les 258 — coïncide exactement.

## Pourquoi ce fichier plutôt qu'une phrase disant « ce ne sont que des commentaires »

`schema_fingerprint.sql` normalise un corps avec trois `regexp_replace` et dit,
dans son propre en-tête, que la normalisation est approximative **dans le sens
dangereux** : elle retire `--` et `/* */` sans savoir s'ils sont dans une chaîne,
donc elle peut faire paraître ÉGALES deux définitions différentes. Elle interdit
de s'en servir pour écarter une divergence.

« Ce ne sont que des commentaires » était donc une supposition.
`scripts/sql_tokens.py` en fait une décision : un vrai lexer PostgreSQL —
commentaires de ligne, blocs imbriqués, échappements `''` et `E'\'`,
dollar-quotes à tag quelconque, identifiants entre guillemets — qui jette les
commentaires et garde **chaque littéral verbatim**, et qui n'ouvre qu'une seule
dollar-quote : le corps que le `AS` de tête introduit. Ses seize sondes incluent
les trois cas que le regex rate ; `--self-test` les rejoue et
`scripts/local-verify.sh` appelle `--self-test`.

Trois verdicts permis et pas de quatrième : **identique**, **écart de
commentaire, prouvé**, **comportement différent**.

| résultat | nombre |
|---|---|
| identique | 0 |
| écart de commentaire, prouvé | 47 |
| comportement différent | 0 |

## D'où viennent les quarante-sept

- **38** figuraient déjà dans l'empreinte de production du 12 septembre.
- **3** sont apparues avec la récupération des onze.
- **6** sont apparues le 17 septembre, quand le dépôt a repris la version
  **longue** des onze (celle de `claude/foundation-lot3-wiring`) : ces six
  fonctions y sont redéfinies, donc le rejeu les produit commentées alors que la
  production porte l'extrait.

## Le sens de l'écart, sur les quarante-sept

**La production est le côté appauvri.** Ce qui a appliqué ces fonctions a retiré
les commentaires en chemin ; le dépôt est le côté long, sans exception. C'est la
règle que le README en tire : ne jamais régénérer un fichier depuis la
production.

Les réécrire pour y remettre la prose serait quarante-sept `create or replace`
sur du code payant qui marche, pour zéro changement de comportement. Ce n'est
pas obviously payant, et ce n'est pas une décision que ce fichier prend.

## L'exemption, et ce qu'elle exempte

`schema_drift_accepted.txt` les porte **par identité ET par les deux
empreintes**. Si l'une des quarante-sept change d'un côté ou de l'autre, le
triplet ne correspond plus et la CI rougit. Une exemption périmée — dont l'objet
a changé ou disparu — est signalée et comptée elle aussi.

| fonction | verdict | origine |
|---|---|---|
| `brand_images_claim` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `brand_images_enabled` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `brand_images_mark_failed` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `brand_images_mark_ready` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `brand_kit_entitled` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `brand_kit_has_generation_credit` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `consume_check_rewrite` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `consume_generation_credit` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `direction_assets_claim` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `direction_limits` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `directory_structured_valid` | écart de commentaire, prouvé | prose reprise de la version longue des onze, 17-09 |
| `enforce_direction_selection_entitlement` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `get_brand_asset_manifest` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `get_brand_images` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `get_directory_profile` | écart de commentaire, prouvé | prose reprise de la version longue des onze, 17-09 |
| `maintain_site_spec_text_variants` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `nearest_color_name` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `project_briefs_usp_options_valid` | écart de commentaire, prouvé | prose reprise de la version longue des onze, 17-09 |
| `purchase_status_events_apply` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `purchases_kind_matches_plan` | écart de commentaire, prouvé | prose reprise de la version longue des onze, 17-09 |
| `record_platform_refusal` | écart de commentaire, prouvé | prose reprise de la version longue des onze, 17-09 |
| `section_type_fields_valid` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `seed_launch_checklist` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `set_launch_step` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_catalog` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_output_fragments` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_output_get` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_output_mark_copied` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_accent_try` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_copy_blocks` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_credential_line` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_cta_ink` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_derive_accent` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_fix_contrast` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_hero_valid` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_hue_tolerance` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_identity_lines` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_lab` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_output_prompt` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_output_setup_sheet` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_pages_valid` | écart de commentaire, prouvé | prose reprise de la version longue des onze, 17-09 |
| `site_spec_preview_model` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_seed_clamped_valid` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_seed_values` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_suggest_hex` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_text_variant` | écart de commentaire, prouvé | commentaires retirés à l'application |
| `site_spec_voice_guide` | écart de commentaire, prouvé | commentaires retirés à l'application |
