# FRONTEND_CONTRACT.md

The site spec editor, as the database exposes it.

This file is complete. Build against it without reading a migration.

Everything here was captured from a live database, not written by hand. Where a
value is enumerable it is enumerated.

---

## 1. Calling convention

Every entry point is a Postgres function, reached over PostgREST RPC:

```
POST /rest/v1/rpc/<function_name>
Authorization: Bearer <the user's JWT>
Content-Type: application/json

{ "p_brand_kit_id": "33333333-…", … }
```

Argument names are the function's parameter names, `p_`-prefixed. They are
listed per entry below.

**Forward the user's JWT.** `auth.uid()` is what scopes every one of these.

> ⚠ **Never call these with `service_role`.** `auth.uid()` is NULL on a
> service-role connection, so a service-role call receives
> `{"error":{"code":"unauthenticated", …}}`. It does not receive somebody
> else's data — but it also does not work. The route handler must forward the
> caller's token.

Another user's brand kit returns `not_found`, byte-identical to a kit that does
not exist. There is no `forbidden`.

### The eleven entries

| Product endpoint | RPC function | Arguments |
|---|---|---|
| `GET /brand-kits/:id/site-spec` | `site_spec_get` | `p_brand_kit_id uuid` |
| `PATCH /brand-kits/:id/site-spec` | `site_spec_patch` | `p_brand_kit_id uuid`, `p_patch jsonb` |
| `POST /brand-kits/:id/site-spec/reset` | `site_spec_reset` | `p_brand_kit_id uuid`, `p_scope text` |
| `POST /brand-kits/:id/site-spec/target` | `site_spec_set_target` | `p_brand_kit_id uuid`, `p_target text` |
| `GET /brand-kits/:id/site-output` | `site_output_get` | `p_brand_kit_id uuid`, `p_target text`, `p_format text` |
| `POST /brand-kits/:id/site-output/mark-copied` | `site_output_mark_copied` | `p_brand_kit_id uuid` |
| `POST /brand-kits/:id/site-spec/fix-contrast` | `site_spec_fix_contrast` | `p_brand_kit_id uuid`, `p_pair_id text` |
| `GET /catalog` (site-spec blocks) | `site_catalog` | none |
| `POST /brand-kits/:id/direction` | `brand_kit_select_direction` | `p_brand_kit_id uuid`, `p_direction_id text` |
| — (call before any model call) | `consume_generation_credit` | `p_brand_kit_id uuid` |
| `GET /brand-kits/:id/entitled` | `brand_kit_entitled` | `p_brand_kit_id uuid` |
| — (checkout handler, **service_role**) | `grant_plan_allowance` | `p_project_id uuid`, `p_tier text`, `p_grant_key text` |

`p_scope` ∈ `all` `colors` `typography` `copy` `structure`.
`p_target` ∈ `lovable` `framer` `v0` `generic` `squarespace` `wix` `webflow`.
`p_format` ∈ `json` `md` `txt` (default `json`).
`p_pair_id` ∈ the seven ids in section 4.

Seven return **the same envelope** (section 2): `site_spec_get`,
`site_spec_patch`, `site_spec_reset`, `site_spec_set_target`,
`site_output_mark_copied`, `site_spec_fix_contrast` and
`brand_kit_select_direction`. `site_output_get` returns the output alone.
`site_catalog` returns the catalog. `consume_generation_credit` and
`brand_kit_entitled` return a bare boolean.

---

### Payment

> ⚠ **This changed at `20260829123000`, and it changed what your routes are
> allowed to assume.** There was no paywall: `paid` was a client-side branch, no
> route read `purchases`, and everything downstream hung off
> `selected_direction_id`. A signed-in account got the kit, the PDF and the site
> editor for free.

**The reveal is free.** Generating three directions and looking at them costs
nothing, because that is the sales pitch. **Everything from choosing a direction
onward is paid.**

| RPC | unentitled owner |
|---|---|
| `site_catalog` | **works** — it describes the product she is being asked to buy |
| `brand_kit_entitled` | **works** — it is how you decide what to render |
| `consume_generation_credit` | **works** — the free allowance is metered, not blocked |
| `brand_kit_select_direction` | `payment_required` |
| `site_spec_get`, `site_output_get` | `payment_required` |
| `site_spec_patch`, `site_spec_reset`, `site_spec_set_target` | `payment_required` |
| `site_spec_fix_contrast`, `site_output_mark_copied` | `payment_required` |

The reads refuse too, because the output **is** the deliverable.

**Do not re-implement the check.** `brand_kit_entitled(p_brand_kit_id)` is the
only definition of "she has paid for this kit"; every gated RPC calls it, and a
second copy in a route is a copy that drifts.

> **A route that reads `brand_kits` through PostgREST rather than through the
> gated RPCs — the PDF route, the brand kit page — must call
> `brand_kit_entitled` and nothing else to ask whether she has paid.** It is
> exposed for exactly that, `auth.uid()`-scoped the same way, and it is the one
> place the sentence is written.

Call it to decide what to *render* — a checkout button instead of an editor.
Never call it to decide whether to *allow* something a gated RPC does: that RPC
has already decided, and it is the one holding the line.

It returns a bare boolean, and **`false` deliberately covers three states**: not
signed in, not her kit, and hers but unbought. That is the disclosure ordering
of the gated seven expressed in one bit — a stranger's kit answers exactly as an
unpaid one does, so probing ids learns nothing. When you need to tell the last
two apart in order to *render* — checkout versus "no such kit" — get that from
the gated RPC you were going to call anyway: it returns `payment_required` or
`not_found` and has already applied the same ordering.

`anon` cannot execute it, or any of the entitlement RPCs. These are questions
about a signed-in person's own kit; an anonymous caller has none.

Writing `brand_kits.selected_direction_id` directly is refused by a trigger, not
just by the RPC, so a route that reaches for the table instead of
`brand_kit_select_direction` gets a `42501` rather than a silent bypass.

Entitling statuses are `paid` and `partially_refunded`. `pending`, `failed`,
`refunded` and `disputed` are not — a partial refund is a discount after the
fact, a dispute is money in escrow and the deliverable comes back until it
closes.

### ETag

The envelope carries `etag`. Hand it back as `If-None-Match`.

It is an md5 over six inputs:

| input | moves when |
|---|---|
| `brand_kit_id` | never, for a given spec |
| `spec_version` | any write to the spec itself |
| `last_copied_spec_version` | **mark-copied, and nothing else** |
| `target` | the builder is switched (also bumps `spec_version`) |
| a catalog fingerprint | the output copy is tuned — `site_output_templates`, `section_types`, `builder_targets` |
| the kit's `voice_guide` | the Ethics Guard rewrites it on `brand_kits` — **not on the spec row at all** |

Those are every input to every key of the envelope. `preview`, `contrast` and
`diff` read the spec row only. `output` reads the spec row, the three catalogs
and the kit's voice guide. Nothing else is consulted.

> ⚠ **Three of those six were missing at one point, all with the same shape.**
> The etag used to be `(brand_kit_id, spec_version, target)`. `mark-copied`
> moves none of them, so a client would 304 and keep the staleness banner on
> screen after the copy that clears it. Tuning the output copy had the same
> problem, and so did the voice guide — it is the only envelope input that does
> not live on `site_specs`, so editing it changed the deliverable while every
> etag input held still. All three are fixed (`20260829116000`, `20260829120000`);
> the table above is current.
>
> The lesson generalises: **anything new that reaches the output must be added
> to the etag in the same commit.** The output is not a function of the spec row
> alone.

Verified behaviour, by real calls:

| action | etag |
|---|---|
| two identical reads | **unchanged** |
| a patch with `{}` | **unchanged** |
| a patch setting a field to its current value | **unchanged** |
| a patch that is refused | **unchanged** |
| a second, redundant `mark-copied` | **unchanged** |
| `mark-copied` that clears the banner | **moves** |
| any real edit | **moves** |
| a target switch | **moves** |
| a contrast fix | **moves** |
| a reset | **moves** |
| an output copy tuning | **moves** |
| an edit to the kit's `voice_guide` | **moves** |

#### ⚠ Two things about how any of this gets verified

- **An assertion that passes because the state it checks was never reached proves
  nothing.** A "mark-copied clears the banner" check ran green for a whole lot
  while `last_copied_spec_version` was NULL and the banner had never been up —
  it was clearing something that was already clear. When a test asserts that an
  action changes a state, assert the state was in the *other* value first.
- **This project's tests run against a less defensive `auth.uid()` than
  production ships.** The local harness cast `request.jwt.claims` to `jsonb`
  before neutralising the empty string, so a blank GUC raised instead of
  returning NULL; Supabase's shipped definition guards it first. The harness is
  now aligned, but anything that depends on the exact behaviour of an absent or
  blank JWT should be confirmed against a real Supabase instance, not this one.

---

## 2. The envelope, as real JSON

Captured from `site_spec_get` on a CLAY & SAND kit: four enabled pages, real
copy, `extra_instructions` set, a practitioner named, and the kit's voice guide
present. 18972 bytes minified. This is the complete response.

⚠ **Every contrast pair passes in it** — `passes_aa: true`, worst 4.51 — because
the derived colours of section 3 do their job on a shipped palette. So every
`suggested_fix` in it is `null`. The non-null shape is shown in section 4; do
not infer from this envelope that the field is always null.

```json
{
    "diff": {
        "stale": true,
        "changes": [
            {
                "area": "copy",
                "label": "About text edited"
            }
        ]
    },
    "etag": "f0857fa29f05fdd0650bb12719857863",
    "spec": {
        "hero": {
            "subhead": "Therapy for adults who hold it together.",
            "headline": "A calmer place to start.",
            "overline": "LCSW · PORTLAND, OR",
            "cta_label": "Book a consult",
            "cta_target_url": "https://elmandember.clientsecure.me/book"
        },
        "pages": [
            {
                "key": "home",
                "label": "Home",
                "enabled": true,
                "sections": [
                    {
                        "key": "hero",
                        "type": "hero",
                        "order": 1,
                        "fields": {
                        },
                        "enabled": true
                    },
                    {
                        "key": "intro",
                        "type": "intro",
                        "order": 2,
                        "fields": {
                        },
                        "enabled": true
                    },
                    {
                        "key": "specialties",
                        "type": "specialties",
                        "order": 3,
                        "fields": {
                            "items": [
                                "Anxiety",
                                "Burnout",
                                "Life transitions"
                            ],
                            "heading": "What I work with"
                        },
                        "enabled": true
                    },
                    {
                        "key": "who_i_work_with",
                        "type": "who_i_work_with",
                        "order": 4,
                        "fields": {
                            "items": [
                                "Professionals who look fine from the outside",
                                "Adults carrying something from years back"
                            ],
                            "heading": "Who I work with"
                        },
                        "enabled": true
                    },
                    {
                        "key": "contact",
                        "type": "contact",
                        "order": 5,
                        "fields": {
                            "body": "A consult is fifteen minutes on the phone, at no charge.",
                            "heading": "Get in touch"
                        },
                        "enabled": true
                    },
                    {
                        "key": "footer",
                        "type": "footer",
                        "order": 6,
                        "fields": {
                            "body": "Elm & Ember Therapy, PLLC. Licensed in Oregon."
                        },
                        "enabled": true
                    }
                ]
            },
            {
                "key": "about",
                "label": "About",
                "enabled": true,
                "sections": [
                    {
                        "key": "intro",
                        "type": "intro",
                        "order": 1,
                        "fields": {
                        },
                        "enabled": true
                    },
                    {
                        "key": "approach",
                        "type": "approach",
                        "order": 2,
                        "fields": {
                            "body": "Sessions are fifty minutes, weekly to start. You set the pace.",
                            "heading": "How I work"
                        },
                        "enabled": true
                    },
                    {
                        "key": "credentials",
                        "type": "credentials",
                        "order": 3,
                        "fields": {
                            "items": [
                                "Licensed Clinical Social Worker, Oregon #LC61234",
                                "MSW, Portland State University"
                            ],
                            "heading": "Training and licensure"
                        },
                        "enabled": true
                    },
                    {
                        "key": "footer",
                        "type": "footer",
                        "order": 4,
                        "fields": {
                            "body": "Elm & Ember Therapy, PLLC. Licensed in Oregon."
                        },
                        "enabled": true
                    }
                ]
            },
            {
                "key": "services",
                "label": "Services",
                "enabled": true,
                "sections": [
                    {
                        "key": "services",
                        "type": "services",
                        "order": 1,
                        "fields": {
                            "body": "Individual therapy for adults, in person and by video in Oregon.",
                            "items": [
                                "Individual therapy, 50 minutes, weekly"
                            ],
                            "heading": "Services"
                        },
                        "enabled": true
                    },
                    {
                        "key": "fees",
                        "type": "fees",
                        "order": 2,
                        "fields": {
                            "body": "Out of network, with a monthly superbill.",
                            "items": [
                                "$185 per 50-minute session"
                            ],
                            "heading": "Fees"
                        },
                        "enabled": true
                    },
                    {
                        "key": "faq",
                        "type": "faq",
                        "order": 3,
                        "fields": {
                            "items": [
                            ],
                            "heading": "Common questions"
                        },
                        "enabled": false
                    },
                    {
                        "key": "footer",
                        "type": "footer",
                        "order": 4,
                        "fields": {
                            "body": "Elm & Ember Therapy, PLLC. Licensed in Oregon."
                        },
                        "enabled": true
                    }
                ]
            },
            {
                "key": "contact",
                "label": "Contact",
                "enabled": true,
                "sections": [
                    {
                        "key": "contact",
                        "type": "contact",
                        "order": 1,
                        "fields": {
                            "body": "The fastest way to reach me is the booking link.",
                            "heading": "Get in touch"
                        },
                        "enabled": true
                    },
                    {
                        "key": "footer",
                        "type": "footer",
                        "order": 2,
                        "fields": {
                            "body": "Elm & Ember Therapy, PLLC. Licensed in Oregon."
                        },
                        "enabled": true
                    }
                ]
            }
        ],
        "paper": "#FAF6EE",
        "accent": "#6E3320",
        "target": "squarespace",
        "primary": "#B4674A",
        "body_font": "Nunito Sans",
        "secondary": "#C08A3E",
        "updated_at": "2026-08-29T17:14:32.593791+00:00",
        "brand_kit_id": "33333333-3333-3333-3333-333333333333",
        "dark_neutral": "#2B2A27",
        "heading_font": "Fraunces",
        "seed_clamped": null,
        "spec_version": 4,
        "about_excerpt": "I work mostly with professionals who look fine from the outside. Much of that work sits with anxiety and burnout.",
        "light_neutral": "#F4EEE3",
        "type_pairing_id": "fraunces_nunito",
        "google_fonts_url": "https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Nunito+Sans:wght@400;600;700&display=swap",
        "practice_details": {
            "city": "Portland",
            "email": "hello@elmandember.com",
            "phone": "(503) 555-0123",
            "state": "OR",
            "license_label": "LCSW",
            "practice_name": "Elm & Ember Therapy",
            "license_number": "LC61234",
            "practitioner_name": "Nora Whitfield"
        },
        "extra_instructions": "Please keep the fee off the home page. Tuesday and Thursday are the only hours open right now.",
        "last_copied_spec_version": 3
    },
    "output": {
        "kind": "setup_sheet",
        "steps": [
            {
                "n": 1,
                "body": "Pick a template that is already close to the structure below. You will delete more than you add.",
                "title": "Start from the right template",
                "values": [
                ],
                "builder_hint": "Start from a one-page portfolio or personal template, then delete the sections you do not need."
            },
            {
                "n": 2,
                "body": "Enter each hex exactly as written and give it the role named next to it. Do not let the template keep its own palette alongside yours.",
                "title": "Set your six colors",
                "values": [
                    {
                        "kind": "hex",
                        "label": "Primary — fills, buttons, bands and borders",
                        "value": "#B4674A"
                    },
                    {
                        "kind": "hex",
                        "label": "Secondary — supporting surfaces and fills",
                        "value": "#C08A3E"
                    },
                    {
                        "kind": "hex",
                        "label": "Accent — small marks, rules and selected states",
                        "value": "#6E3320"
                    },
                    {
                        "kind": "hex",
                        "label": "Page background — the whole page sits on this",
                        "value": "#FAF6EE"
                    },
                    {
                        "kind": "hex",
                        "label": "Section background — tinted bands and cards only",
                        "value": "#F4EEE3"
                    },
                    {
                        "kind": "hex",
                        "label": "Dark neutral — body text",
                        "value": "#2B2A27"
                    }
                ],
                "builder_hint": "Site Styles › Colors"
            },
            {
                "n": 3,
                "body": "These are the same three brand colors, darkened just enough to be readable as text on your page background. Add them alongside the others. Use them for headings and links; keep the brighter originals for fills, bands and buttons.",
                "title": "Add the text versions of those three colors",
                "values": [
                    {
                        "kind": "hex",
                        "label": "Primary as text — headings and links on the page",
                        "value": "#A35D43"
                    },
                    {
                        "kind": "hex",
                        "label": "Secondary as text — supporting headings on the page",
                        "value": "#92692F"
                    },
                    {
                        "kind": "hex",
                        "label": "Accent as text — small highlighted words",
                        "value": "#6E3320"
                    }
                ],
                "builder_hint": "Site Styles › Colors"
            },
            {
                "n": 4,
                "body": "Both faces are on Google Fonts. Assign the heading face to every heading level and the body face to body text, buttons and navigation.",
                "title": "Set your fonts",
                "values": [
                    {
                        "kind": "font",
                        "label": "Heading font",
                        "value": "Fraunces"
                    },
                    {
                        "kind": "font",
                        "label": "Body font",
                        "value": "Nunito Sans"
                    },
                    {
                        "kind": "url",
                        "label": "Google Fonts stylesheet",
                        "value": "https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Nunito+Sans:wght@400;600;700&display=swap"
                    }
                ],
                "builder_hint": "Site Styles › Fonts"
            },
            {
                "n": 5,
                "body": "Add each page, then each section inside it, top to bottom. The line after each section says what it is for.\n\n1. Home\n   1. Hero — The first screen: a short overline, one headline, one supporting line, and a single call to action.\n   2. Introduction — One paragraph in the practitioner's own voice, placed directly under the hero.\n   3. What I work with — A short list of the areas the practice works in. Plain labels, not diagnoses aimed at the reader.\n   4. Who I work with — Who the practice serves, written as lived situations rather than diagnostic labels.\n   5. Contact — How to get in touch, ending in the call to action. No form that collects health information.\n   6. Footer — Practice name, license and location, and nothing that needs to be read twice.\n2. About\n   1. Introduction — One paragraph in the practitioner's own voice, placed directly under the hero.\n   2. How I work — What a session is actually like, so a visitor knows before they have to ask.\n   3. Training and licensure — License, degrees and completed training. Facts only, in the order the practitioner lists them.\n   4. Footer — Practice name, license and location, and nothing that needs to be read twice.\n3. Services\n   1. Services — What the practice offers: individual work, couples work, consultation.\n   2. Fees — Session fee, sliding scale and insurance, stated plainly so the first call is not about the number.\n   3. Footer — Practice name, license and location, and nothing that needs to be read twice.\n4. Contact\n   1. Contact — How to get in touch, ending in the call to action. No form that collects health information.\n   2. Footer — Practice name, license and location, and nothing that needs to be read twice.",
                "title": "Build the pages and sections in this order",
                "values": [
                ],
                "builder_hint": "Pages › Edit › Add Section"
            },
            {
                "n": 6,
                "body": "These go in your footer and on your contact page. Your name and license belong together wherever either appears — most boards require it.",
                "title": "Fill in your practice details",
                "values": [
                    {
                        "kind": "text",
                        "label": "Name",
                        "value": "Elm & Ember Therapy"
                    },
                    {
                        "kind": "text",
                        "label": "Licensed practitioner",
                        "value": "Nora Whitfield, LCSW #LC61234"
                    },
                    {
                        "kind": "text",
                        "label": "Location",
                        "value": "Portland, OR"
                    },
                    {
                        "kind": "text",
                        "label": "Email",
                        "value": "hello@elmandember.com"
                    },
                    {
                        "kind": "text",
                        "label": "Phone",
                        "value": "(503) 555-0123"
                    }
                ],
                "builder_hint": null
            },
            {
                "n": 7,
                "body": "Every string your site needs is listed below this sheet, one block per field, in the order the sections appear. Paste them as they are.",
                "title": "Paste your copy",
                "values": [
                ],
                "builder_hint": null
            },
            {
                "n": 8,
                "body": "Set every call-to-action button to this link. One destination, on every page.",
                "title": "Point the button at your booking link",
                "values": [
                    {
                        "kind": "text",
                        "label": "Button label",
                        "value": "Book a consult"
                    },
                    {
                        "kind": "url",
                        "label": "Button links to",
                        "value": "https://elmandember.clientsecure.me/book"
                    },
                    {
                        "kind": "hex",
                        "label": "Button label color",
                        "value": "#10100F"
                    },
                    {
                        "kind": "text",
                        "label": "Smallest the label may be set",
                        "value": "24px, or 19px if bold"
                    }
                ],
                "builder_hint": null
            },
            {
                "n": 9,
                "body": "A template will ask you for words this sheet does not cover: a menu label, a button, a caption under a photo, the page someone lands on when a link breaks. Write those in your own voice, and check them against the second list before you publish.\n\nAnything you write that is not in the copy above — navigation labels, button microcopy, alt text, form labels, error messages, a 404 page — must sound like the first list and must never sound like the second.\n\nSounds like:\n- Plain, unhurried sentences. No throat-clearing.\n- Say the hard thing kindly rather than softening it away.\n- Write to one person who is already tired, not to an audience.\n\nNever write:\n- Heal your anxiety in 12 weeks.\n- My clients often tell me I changed their lives.\n- Limited spots available - book now!",
                "title": "Keep these in view when you write anything else",
                "values": [
                ],
                "builder_hint": null
            },
            {
                "n": 10,
                "body": "[ ] Use the provided copy exactly as written. Do not rewrite, expand or add copy.\n[ ] Do not invent testimonials, client quotes, statistics, credentials or awards.\n[ ] No stock photos of people; leave labeled image placeholders.\n[ ] The call to action links to https://elmandember.clientsecure.me/book. Do not add a contact form that collects health information — a mailto link, a phone number or a booking link only.\n[ ] Do not set the call-to-action label below 24px, or 19px if it is bold. The button's two colors were checked for text at that size; keep the label at or above it and the pair stays legible.\n[ ] Maintain WCAG AA text contrast.",
                "title": "Before you publish",
                "values": [
                ],
                "builder_hint": null
            },
            {
                "n": 11,
                "body": "Please keep the fee off the home page. Tuesday and Thursday are the only hours open right now.",
                "title": "Your own notes",
                "values": [
                ],
                "builder_hint": null
            }
        ],
        "copy_blocks": [
            {
                "page": "Home",
                "text": "LCSW · PORTLAND, OR",
                "label": "Overline",
                "section": "Hero"
            },
            {
                "page": "Home",
                "text": "A calmer place to start.",
                "label": "Headline",
                "section": "Hero"
            },
            {
                "page": "Home",
                "text": "Therapy for adults who hold it together.",
                "label": "Supporting line",
                "section": "Hero"
            },
            {
                "page": "Home",
                "text": "Book a consult",
                "label": "Button label",
                "section": "Hero"
            },
            {
                "page": "Home",
                "text": "https://elmandember.clientsecure.me/book",
                "label": "Button links to",
                "section": "Hero"
            },
            {
                "page": "Home",
                "text": "I work mostly with professionals who look fine from the outside. Much of that work sits with anxiety and burnout.",
                "label": "Paragraph",
                "section": "Introduction"
            },
            {
                "page": "Home",
                "text": "What I work with",
                "label": "Heading",
                "section": "What I work with"
            },
            {
                "page": "Home",
                "text": "Anxiety",
                "label": "Areas 1",
                "section": "What I work with"
            },
            {
                "page": "Home",
                "text": "Burnout",
                "label": "Areas 2",
                "section": "What I work with"
            },
            {
                "page": "Home",
                "text": "Life transitions",
                "label": "Areas 3",
                "section": "What I work with"
            },
            {
                "page": "Home",
                "text": "Who I work with",
                "label": "Heading",
                "section": "Who I work with"
            },
            {
                "page": "Home",
                "text": "Professionals who look fine from the outside",
                "label": "Descriptions 1",
                "section": "Who I work with"
            },
            {
                "page": "Home",
                "text": "Adults carrying something from years back",
                "label": "Descriptions 2",
                "section": "Who I work with"
            },
            {
                "page": "Home",
                "text": "Get in touch",
                "label": "Heading",
                "section": "Contact"
            },
            {
                "page": "Home",
                "text": "A consult is fifteen minutes on the phone, at no charge.",
                "label": "Paragraph",
                "section": "Contact"
            },
            {
                "page": "Home",
                "text": "Elm & Ember Therapy, PLLC. Licensed in Oregon.",
                "label": "Footer note",
                "section": "Footer"
            },
            {
                "page": "About",
                "text": "I work mostly with professionals who look fine from the outside. Much of that work sits with anxiety and burnout.",
                "label": "Paragraph",
                "section": "Introduction"
            },
            {
                "page": "About",
                "text": "How I work",
                "label": "Heading",
                "section": "How I work"
            },
            {
                "page": "About",
                "text": "Sessions are fifty minutes, weekly to start. You set the pace.",
                "label": "Paragraph",
                "section": "How I work"
            },
            {
                "page": "About",
                "text": "Training and licensure",
                "label": "Heading",
                "section": "Training and licensure"
            },
            {
                "page": "About",
                "text": "Licensed Clinical Social Worker, Oregon #LC61234",
                "label": "Credentials 1",
                "section": "Training and licensure"
            },
            {
                "page": "About",
                "text": "MSW, Portland State University",
                "label": "Credentials 2",
                "section": "Training and licensure"
            },
            {
                "page": "About",
                "text": "Elm & Ember Therapy, PLLC. Licensed in Oregon.",
                "label": "Footer note",
                "section": "Footer"
            },
            {
                "page": "Services",
                "text": "Services",
                "label": "Heading",
                "section": "Services"
            },
            {
                "page": "Services",
                "text": "Individual therapy for adults, in person and by video in Oregon.",
                "label": "Introduction",
                "section": "Services"
            },
            {
                "page": "Services",
                "text": "Individual therapy, 50 minutes, weekly",
                "label": "Services 1",
                "section": "Services"
            },
            {
                "page": "Services",
                "text": "Fees",
                "label": "Heading",
                "section": "Fees"
            },
            {
                "page": "Services",
                "text": "Out of network, with a monthly superbill.",
                "label": "Introduction",
                "section": "Fees"
            },
            {
                "page": "Services",
                "text": "$185 per 50-minute session",
                "label": "Lines 1",
                "section": "Fees"
            },
            {
                "page": "Services",
                "text": "Elm & Ember Therapy, PLLC. Licensed in Oregon.",
                "label": "Footer note",
                "section": "Footer"
            },
            {
                "page": "Contact",
                "text": "Get in touch",
                "label": "Heading",
                "section": "Contact"
            },
            {
                "page": "Contact",
                "text": "The fastest way to reach me is the booking link.",
                "label": "Paragraph",
                "section": "Contact"
            },
            {
                "page": "Contact",
                "text": "Elm & Ember Therapy, PLLC. Licensed in Oregon.",
                "label": "Footer note",
                "section": "Footer"
            }
        ]
    },
    "preview": {
        "pages": [
            {
                "key": "home",
                "label": "Home",
                "sections": [
                    {
                        "key": "hero",
                        "type": "hero",
                        "order": 1,
                        "fields": {
                            "subhead": "Therapy for adults who hold it together.",
                            "headline": "A calmer place to start.",
                            "overline": "LCSW · PORTLAND, OR",
                            "cta_label": "Book a consult",
                            "cta_target_url": "https://elmandember.clientsecure.me/book"
                        }
                    },
                    {
                        "key": "intro",
                        "type": "intro",
                        "order": 2,
                        "fields": {
                            "body": "I work mostly with professionals who look fine from the outside. Much of that work sits with anxiety and burnout."
                        }
                    },
                    {
                        "key": "specialties",
                        "type": "specialties",
                        "order": 3,
                        "fields": {
                            "items": [
                                "Anxiety",
                                "Burnout",
                                "Life transitions"
                            ],
                            "heading": "What I work with"
                        }
                    },
                    {
                        "key": "who_i_work_with",
                        "type": "who_i_work_with",
                        "order": 4,
                        "fields": {
                            "items": [
                                "Professionals who look fine from the outside",
                                "Adults carrying something from years back"
                            ],
                            "heading": "Who I work with"
                        }
                    },
                    {
                        "key": "contact",
                        "type": "contact",
                        "order": 5,
                        "fields": {
                            "body": "A consult is fifteen minutes on the phone, at no charge.",
                            "heading": "Get in touch"
                        }
                    },
                    {
                        "key": "footer",
                        "type": "footer",
                        "order": 6,
                        "fields": {
                            "body": "Elm & Ember Therapy, PLLC. Licensed in Oregon."
                        }
                    }
                ]
            },
            {
                "key": "about",
                "label": "About",
                "sections": [
                    {
                        "key": "intro",
                        "type": "intro",
                        "order": 1,
                        "fields": {
                            "body": "I work mostly with professionals who look fine from the outside. Much of that work sits with anxiety and burnout."
                        }
                    },
                    {
                        "key": "approach",
                        "type": "approach",
                        "order": 2,
                        "fields": {
                            "body": "Sessions are fifty minutes, weekly to start. You set the pace.",
                            "heading": "How I work"
                        }
                    },
                    {
                        "key": "credentials",
                        "type": "credentials",
                        "order": 3,
                        "fields": {
                            "items": [
                                "Licensed Clinical Social Worker, Oregon #LC61234",
                                "MSW, Portland State University"
                            ],
                            "heading": "Training and licensure"
                        }
                    },
                    {
                        "key": "footer",
                        "type": "footer",
                        "order": 4,
                        "fields": {
                            "body": "Elm & Ember Therapy, PLLC. Licensed in Oregon."
                        }
                    }
                ]
            },
            {
                "key": "services",
                "label": "Services",
                "sections": [
                    {
                        "key": "services",
                        "type": "services",
                        "order": 1,
                        "fields": {
                            "body": "Individual therapy for adults, in person and by video in Oregon.",
                            "items": [
                                "Individual therapy, 50 minutes, weekly"
                            ],
                            "heading": "Services"
                        }
                    },
                    {
                        "key": "fees",
                        "type": "fees",
                        "order": 2,
                        "fields": {
                            "body": "Out of network, with a monthly superbill.",
                            "items": [
                                "$185 per 50-minute session"
                            ],
                            "heading": "Fees"
                        }
                    },
                    {
                        "key": "footer",
                        "type": "footer",
                        "order": 4,
                        "fields": {
                            "body": "Elm & Ember Therapy, PLLC. Licensed in Oregon."
                        }
                    }
                ]
            },
            {
                "key": "contact",
                "label": "Contact",
                "sections": [
                    {
                        "key": "contact",
                        "type": "contact",
                        "order": 1,
                        "fields": {
                            "body": "The fastest way to reach me is the booking link.",
                            "heading": "Get in touch"
                        }
                    },
                    {
                        "key": "footer",
                        "type": "footer",
                        "order": 2,
                        "fields": {
                            "body": "Elm & Ember Therapy, PLLC. Licensed in Oregon."
                        }
                    }
                ]
            }
        ],
        "tokens": {
            "paper": "#FAF6EE",
            "accent": "#6E3320",
            "cta_ink": "#10100F",
            "primary": "#B4674A",
            "body_font": "Nunito Sans",
            "secondary": "#C08A3E",
            "accent_text": "#6E3320",
            "dark_neutral": "#2B2A27",
            "heading_font": "Fraunces",
            "primary_text": "#A35D43",
            "light_neutral": "#F4EEE3",
            "secondary_text": "#92692F",
            "google_fonts_url": "https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Nunito+Sans:wght@400;600;700&display=swap"
        },
        "practice_name": "Elm & Ember Therapy"
    },
    "contrast": {
        "pairs": [
            {
                "bg": "#B4674A",
                "fg": "#10100F",
                "label": "Button label on your primary color",
                "level": "AA",
                "ratio": 4.51,
                "pair_id": "cta_label_on_primary",
                "suggested_fix": null
            },
            {
                "bg": "#FAF6EE",
                "fg": "#2B2A27",
                "label": "Body text on the page",
                "level": "AAA",
                "ratio": 13.31,
                "pair_id": "dark_neutral_on_paper",
                "suggested_fix": null
            },
            {
                "bg": "#FAF6EE",
                "fg": "#A35D43",
                "label": "Primary color as text on the page",
                "level": "AA",
                "ratio": 4.63,
                "pair_id": "primary_on_paper",
                "suggested_fix": null
            },
            {
                "bg": "#FAF6EE",
                "fg": "#92692F",
                "label": "Secondary color as text on the page",
                "level": "AA",
                "ratio": 4.55,
                "pair_id": "secondary_on_paper",
                "suggested_fix": null
            },
            {
                "bg": "#FAF6EE",
                "fg": "#6E3320",
                "label": "Accent color as text on the page",
                "level": "AAA",
                "ratio": 9.03,
                "pair_id": "accent_on_paper",
                "suggested_fix": null
            },
            {
                "bg": "#F4EEE3",
                "fg": "#2B2A27",
                "label": "Body text on a tinted section",
                "level": "AAA",
                "ratio": 12.43,
                "pair_id": "dark_neutral_on_light_neutral",
                "suggested_fix": null
            },
            {
                "bg": "#2B2A27",
                "fg": "#FAF6EE",
                "label": "Light text on a dark section",
                "level": "AAA",
                "ratio": 13.31,
                "pair_id": "paper_on_dark_neutral",
                "suggested_fix": null
            }
        ],
        "passes_aa": true,
        "worst_ratio": 4.51
    }
}
```

### `practice_details` — the eight keys

An object, patchable key by key. Every value is a string or `null`; an unknown
key is refused with `unknown_field` naming the key you typed, so a typo is never
silently swallowed.

| key | seeded from | notes |
|---|---|---|
| `practitioner_name` | **nothing — see below** | the person, not the practice |
| `practice_name` | `project_briefs.practice_name`, else the project name | |
| `license_label` | `license_types.label` for the brief's `license_type_id` | "LCSW", "LMFT", … |
| `license_number` | nothing | she types it |
| `city` | `project_briefs.city` | |
| `state` | `project_briefs.state` | **two letters**, validated; anything else is `invalid_field` |
| `email` | nothing | not taken from her account |
| `phone` | nothing | |

**The credential line is composed, never stored.** Wherever the license appears
— the prompt's `## Practice` block, the setup sheet's details step, the footer
section a builder renders — the output prints:

```
Licensed practitioner: Nora Whitfield, LCSW #LC61234
```

Every part is optional and **nothing dangles**. With no name it falls back to
`License: LCSW #LC61234`, exactly as before. With a name and no license it
prints `Licensed practitioner: Nora Whitfield`. With a license number and no
label it prints no line at all — a bare `#LC61234` beside no credential reads
like an order number.

Do not send a pre-composed string. There is no field for one, deliberately:
`brand_kits.practitioner_line` already holds `"Nora Whitfield, LCSW"` for the
signature story, and a second composed field would be a second place for the
name to be wrong.

> ⚠ **`practitioner_name` seeds empty, and the frontend has to fix that.**
> Nothing in `project_briefs` answers it — the brief asks for the practice name,
> not the practitioner's. So every spec seeds with the key present and the value
> `null`, and the output prints no name.
>
> That is a compliance gap, not a cosmetic one: the boards that require a
> license number in advertising require the licensee's name alongside it, and
> until the brief carries the answer the deliverable can produce a therapist's
> website that prints her license number and never names her. **Add a question
> to the brief, or ask for it in the site-spec editor.** The key is patchable
> today; only the seed source is missing.

---

### The voice guide

`brand_kits.voice_guide` — `{sounds_like: [...], never_write: [...]}`, written by
the Ethics Guard — is rendered into both output shapes. It is **not** part of the
site spec: it is not in `spec`, it is not patchable through `site_spec_patch`,
and the site-spec editor should not offer it as a field. It is read from the kit
at render time, so an edit there shows up in the next `site_spec_get` (and moves
the etag — see section 1).

In the `prompt` shape it is a `## Voice` section sitting immediately before
`## Constraints`: one sentence saying what it governs, then `Sounds like:` and
`Never write:` as bullet lists. In the `setup_sheet` shape it is a step near the
end, above the pre-publish checklist, framed for a person writing her own words
rather than for a model.

It exists because the constraints only say *do not rewrite her copy*. A builder
still writes navigation labels, button microcopy, alt text, form labels and a
404 page on its own, and without the guide all of it comes out in the model's
default voice — the voice that writes "Limited spots available".

> **If the kit has no guide, or an empty or malformed one, the section is
> omitted entirely** — no heading with nothing under it, in either shape, and
> the setup sheet's remaining steps renumber so there is no gap. Render whatever
> `output` contains; do not reserve space for a section that may not be there.

#### The ethics disclaimer is deliberately not carried over

The old prompt builder appended a long boilerplate ethics disclaimer to every
prompt. **It is not coming back, and this is a decision rather than an
oversight.** What it was trying to do is now done by things that are checkable:
the four advertising constraints in `## Constraints`, and the `never_write` list
above, which is the Ethics Guard's own counter-examples in her own case rather
than generic legal prose. A paragraph of boilerplate at the end of a prompt is
the part a model skims; a short list of sentences never to write is the part it
can act on. Do not restore the old wording, and do not add it client-side.

### The PATCH response

Identical envelope. Below, `spec.pages`, `preview.pages` and `output` are
elided for length — they are present and identical in shape to the read above.

> ⚠ Re-captured at `20260829120000`. If you are holding an older copy of this
> block, its `cta_label_on_primary` pair showed `fg: "#FFFFFF"` at 4.22 with a
> `suggested_fix` that moved `primary`. That is no longer reachable: the button
> label is painted in the derived `cta_ink` (section 3), which is why the pair
> now reads `#10100F` at 4.51 with no fix. Nothing about the shape changed.

Request: `{"p_brand_kit_id":"33333333-…","p_patch":{"hero":{"headline":"A calmer place to begin."}}}`

```json
{
    "diff": {
        "stale": true,
        "changes": [
            {
                "area": "copy",
                "label": "About text edited"
            },
            {
                "area": "copy",
                "label": "Hero copy edited"
            }
        ]
    },
    "etag": "e08594abf9876454472fed82551bb519",
    "spec": {
        "hero": {
            "subhead": "Therapy for adults who hold it together.",
            "headline": "A calmer place to begin.",
            "overline": "LCSW · PORTLAND, OR",
            "cta_label": "Book a consult",
            "cta_target_url": "https://elmandember.clientsecure.me/book"
        },
        "paper": "#FAF6EE",
        "accent": "#6E3320",
        "target": "squarespace",
        "primary": "#B4674A",
        "body_font": "Nunito Sans",
        "secondary": "#C08A3E",
        "updated_at": "2026-08-29T17:16:04.430165+00:00",
        "brand_kit_id": "33333333-3333-3333-3333-333333333333",
        "dark_neutral": "#2B2A27",
        "heading_font": "Fraunces",
        "seed_clamped": null,
        "spec_version": 5,
        "about_excerpt": "I work mostly with professionals who look fine from the outside. Much of that work sits with anxiety and burnout.",
        "light_neutral": "#F4EEE3",
        "type_pairing_id": "fraunces_nunito",
        "google_fonts_url": "https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Nunito+Sans:wght@400;600;700&display=swap",
        "practice_details": {
            "city": "Portland",
            "email": "hello@elmandember.com",
            "phone": "(503) 555-0123",
            "state": "OR",
            "license_label": "LCSW",
            "practice_name": "Elm & Ember Therapy",
            "license_number": "LC61234",
            "practitioner_name": "Nora Whitfield"
        },
        "extra_instructions": "Please keep the fee off the home page. Tuesday and Thursday are the only hours open right now.",
        "last_copied_spec_version": 3
    },
    "preview": {
        "tokens": {
            "paper": "#FAF6EE",
            "accent": "#6E3320",
            "cta_ink": "#10100F",
            "primary": "#B4674A",
            "body_font": "Nunito Sans",
            "secondary": "#C08A3E",
            "accent_text": "#6E3320",
            "dark_neutral": "#2B2A27",
            "heading_font": "Fraunces",
            "primary_text": "#A35D43",
            "light_neutral": "#F4EEE3",
            "secondary_text": "#92692F",
            "google_fonts_url": "https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,600&family=Nunito+Sans:wght@400;600;700&display=swap"
        },
        "practice_name": "Elm & Ember Therapy"
    },
    "contrast": {
        "pairs": [
            {
                "bg": "#B4674A",
                "fg": "#10100F",
                "label": "Button label on your primary color",
                "level": "AA",
                "ratio": 4.51,
                "pair_id": "cta_label_on_primary",
                "suggested_fix": null
            },
            {
                "bg": "#FAF6EE",
                "fg": "#2B2A27",
                "label": "Body text on the page",
                "level": "AAA",
                "ratio": 13.31,
                "pair_id": "dark_neutral_on_paper",
                "suggested_fix": null
            },
            {
                "bg": "#FAF6EE",
                "fg": "#A35D43",
                "label": "Primary color as text on the page",
                "level": "AA",
                "ratio": 4.63,
                "pair_id": "primary_on_paper",
                "suggested_fix": null
            },
            {
                "bg": "#FAF6EE",
                "fg": "#92692F",
                "label": "Secondary color as text on the page",
                "level": "AA",
                "ratio": 4.55,
                "pair_id": "secondary_on_paper",
                "suggested_fix": null
            },
            {
                "bg": "#FAF6EE",
                "fg": "#6E3320",
                "label": "Accent color as text on the page",
                "level": "AAA",
                "ratio": 9.03,
                "pair_id": "accent_on_paper",
                "suggested_fix": null
            },
            {
                "bg": "#F4EEE3",
                "fg": "#2B2A27",
                "label": "Body text on a tinted section",
                "level": "AAA",
                "ratio": 12.43,
                "pair_id": "dark_neutral_on_light_neutral",
                "suggested_fix": null
            },
            {
                "bg": "#2B2A27",
                "fg": "#FAF6EE",
                "label": "Light text on a dark section",
                "level": "AAA",
                "ratio": 13.31,
                "pair_id": "paper_on_dark_neutral",
                "suggested_fix": null
            }
        ],
        "passes_aa": true,
        "worst_ratio": 4.51
    }
}
```

Note `spec_version` went to 5 and `diff.stale` is `true`, because
`last_copied_spec_version` is 3.

### Error responses

One shape: `{"error":{"code","message","field"?}}`. `field` is absent when the
error is not about a field. Every code the entries can return:

```json
{
    "too_long": {
        "error": {
            "code": "too_long",
            "field": "hero.headline",
            "message": "This is 91 characters. The limit is 90."
        }
    },
    "not_found": {
        "error": {
            "code": "not_found",
            "message": "No site spec for this brand kit."
        }
    },
    "payment_required": {
        "error": {
            "code": "payment_required",
            "message": "Your three directions are yours to look at. Choosing one, and everything that comes with it, is part of the paid kit."
        }
    },
    "invalid_body": {
        "error": {
            "code": "invalid_body",
            "message": "The update must be a JSON object."
        }
    },
    "invalid_field": {
        "error": {
            "code": "invalid_field",
            "field": "primary",
            "message": "A color must be a hex value like #3B2C3A."
        }
    },
    "invalid_scope": {
        "error": {
            "code": "invalid_scope",
            "field": "scope",
            "message": "Reset all, colors, typography, copy or structure."
        }
    },
    "no_fix_needed": {
        "error": {
            "code": "no_fix_needed",
            "field": "pair_id",
            "message": "Body text on the page already reaches AA contrast."
        }
    },
    "unknown_field": {
        "error": {
            "code": "unknown_field",
            "field": "colour",
            "message": "\"colour\" is not a field of the site spec."
        }
    },
    "invalid_format": {
        "error": {
            "code": "invalid_format",
            "field": "format",
            "message": "Ask for json, md or txt."
        }
    },
    "invalid_target": {
        "error": {
            "code": "invalid_target",
            "field": "target",
            "message": "\"wordpress\" is not a website builder we support."
        }
    }
}
```

Two more exist and are not shown because they need a specific state:

- `unauthenticated` — `{"error":{"code":"unauthenticated","message":"Sign in to open your site spec."}}`, returned by every gated entry when `auth.uid()` is NULL.
- `no_direction` — `{"error":{"code":"no_direction","message":"This brand kit has no chosen direction to reset to."}}`, from `site_spec_reset` only.

**An error means nothing was written.** Validation always precedes the write.

#### ⚠ `payment_required` and `not_found` are different sentences — keep them apart

They are answered in a fixed order, and the order is a disclosure decision:

1. no `auth.uid()` → `unauthenticated`
2. the kit is not hers, or does not exist → `not_found`
3. it is hers and unpaid → `payment_required`
4. it is hers and paid, but there is no spec yet → `not_found`

Step 2 comes before step 3 so that `payment_required` never confirms that
somebody else's kit id exists. Probing ids gets `not_found` and nothing else.

On `payment_required`, **open checkout** — she has a kit, she has not bought it.
On `not_found`, apologise; there is nothing there. Collapsing the two into one
"something went wrong" state is the single most likely way to lose a sale, and
showing "not found" for a kit she is looking at is the most likely way to lose
her trust.

---

### Generation credits

`consume_generation_credit(p_brand_kit_id) → boolean`. Call it **immediately
before the model call**, and do not make the call when it returns false.

> ⚠ **Calling it is the only correct way to check.** Reading
> `generation_credits` and deciding from the numbers is a race: two concurrent
> POSTs read the same count, both see room, and both proceed. This function
> takes the row lock and decides inside a single statement, so the second caller
> re-evaluates against the row the first one left and gets `false`.
>
> The counters are readable so you can *show* her what is left. They are not
> writable — by anyone, including her.

`true` means one run was consumed and you may spend a model call. **`false`
means do not proceed** — and it is the answer for every reason not to: allowance
spent, not signed in, not her kit. It fails closed on purpose.

#### The allowance lives in `plans`, and nowhere else

One row per tier, `free` included. **This is the only place an allowance is
written** — not a column default, not a branch in a function, not a constant in
a route. Changing what a tier grants is an `UPDATE` here.

| tier | label | price | `directions_limit` | `regenerations_limit` | total runs |
|---|---|---|---|---|---|
| `free` | Free | $0 | 3 | 1 | 2 |
| `starter` | Starter | $79 | 3 | 3 | 4 |
| `practice` | Practice | $149 | 3 | 6 | 7 |
| `signature` | Signature | $249 | 3 | 12 | 13 |

- **`directions_limit` is directions produced by one run**, not a number of runs.
- **`regenerations_limit` is runs beyond the first.** Total runs is `1 + it`.

> ⚠ **Read these from `plans`; never hard-code them.** They are data, and
> changing what a tier grants is an `UPDATE` on that table — which is the whole
> reason it exists. A number copied into a route is a number that will be wrong
> the first time one of these moves.

`generation_credits.plan_tier` records which plan a project was granted, and
defaults to `free`. There is no `entitled ? paid : free` branch anywhere:
entitlement decides whether she may open the deliverable, the plan decides how
many runs she may spend, and those are different questions.

#### Granting

`grant_plan_allowance(p_project_id, p_tier, p_grant_key)` — **service_role
only**, from your checkout handler. It sets the project's plan and **resets its
meter**, once per `p_grant_key`.

Pass the Stripe event id (or the checkout session id). A replay finds the key in
`plan_grants` and returns `false` having changed nothing — which matters here
more than usual, because a grant resets the counters and a doubled grant would
hand her the whole allowance twice. Omitting the key falls back to the
project's most recent purchase at that tier; a genuine re-purchase has its own
session id, so it grants again.

> ⚠ **If your checkout handler never calls this, a paying customer stays on the
> free plan.** Entitlement will open the deliverable — that is driven by
> `purchases` — but her allowance will still be two runs. Granting is a separate
> call and nothing infers it.

#### What a refund does to an allowance already spent

**Nothing. It stays consumed.** Entitlement flips — `brand_kit_entitled` goes
false, the gated RPCs return `payment_required` — but the meter does not run
backwards, and the project stays on the plan it was granted. The model calls
were made and paid for by Eklio; a refund does not un-make them.

A re-purchase grants again, with a new key, and that resets the meter. That is
the only thing that does.

### Purchase history

`purchases.status` is the current value and one of `pending`, `paid`,
`partially_refunded`, `refunded`, `disputed`, `failed`.

Every Stripe event that moved it is appended to `purchase_status_events`
(purchase id, unique stripe event id, previous status, new status, amount,
`occurred_at`, raw event type). The table is readable for your own purchases and
writable by nobody — a trigger refuses `UPDATE` and `DELETE` outright, not just
a policy, because a `SECURITY DEFINER` function would sail past a policy.

That history is why a won dispute can be resolved correctly:
`purchase_status_before(purchase_id, 'disputed')` returns what the charge
actually was before the dispute opened — which may be `partially_refunded`, not
`paid`. A single mutable status column could not answer that question, which is
why the dispute case was unrepresentable before.

`paid_at` is kept for every status that implies money was captured, including
`refunded` — that a refund happened does not mean the payment never did.

---

## 3. Color roles

Six. Display them in this order — it goes brand, then surfaces, then ink.

| # | key | Label for the therapist | What it paints | A fix may move it |
|---|---|---|---|---|
| 1 | `primary` | Primary | Buttons, links, active states. | **yes** |
| 2 | `secondary` | Secondary | Supporting headings and surfaces. | **yes** |
| 3 | `accent` | Accent | Small marks only — a check, a selected state, a rule under a heading. Never a large fill. | **yes** |
| 4 | `paper` | Page background | **The whole page.** The largest surface on the site. | **no — never** |
| 5 | `light_neutral` | Section background | Tinted bands and cards sitting *on top of* the page. | **no — never** |
| 6 | `dark_neutral` | Body text | Body copy, and the fill of a dark section. | **yes** |

### Three derived variants — rendered, never edited

`preview.tokens` carries three more values. They are **not** in `spec`, **not**
patchable, and **not** swatches the editor should render as controls. She has no
control that corresponds to one.

| key | What it is | Where to use it |
|---|---|---|
| `primary_text` | `primary`, darkened only as far as 4.5:1 on `paper` requires | headings and links painted in the primary |
| `secondary_text` | same, for `secondary` | supporting headings |
| `accent_text` | same, for `accent` | small highlighted words |
| `cta_ink` | the colour the CTA label is set in: white where white reads on `primary`, otherwise `dark_neutral` darkened until it does | the call-to-action button's label |

**The rule, everywhere a brand colour is painted:** if it is **text**, use the
variant. If it is a **fill** — a background, a button, a band, a rule, a border,
a chip — use the brand colour.

`cta_ink` is the same rule on one more surface: the button's label is text on
the primary *fill*, so it gets a legible value too. `dark_neutral` itself never
moves — it is body text and reads on paper at 13.31; `cta_ink` is a variant of
it scoped to the button.

Where the brand colour already reads as text, **the variant is the brand colour,
the same string**. Ten of the eighteen shipped brand colours need no variant and
come back untouched, so treating the variant as "always different" is wrong;
compare, do not assume.

> ⚠ **Why this exists rather than a corrected brand colour.** 4.5:1 is a *text*
> legibility threshold. CLAY & SAND's `#C08A3E` fails it at 2.80 as text and was
> never a problem as a fill. Correcting the brand colour would have moved it
> ΔE 17 — ochre to a duller olive-gold — on a palette a person chose by hand. So
> nothing she chose changes, and only the text use gets a legible value.

They are maintained by a trigger: change `primary` and `primary_text` is
recomputed on the same write and returned in the same envelope. Change `paper`
and all three are recomputed, because the surface they are measured against
moved.

### ⚠ `paper` and `light_neutral` are not the same colour and not the same job

This is the pair that gets collapsed. Do not collapse it.

- **`paper` is the page.** On CLAY & SAND it is `#FAF6EE`. It is what the
  visitor sees behind everything. Five of the seven contrast pairs are measured
  against it.
- **`light_neutral` is a band.** On CLAY & SAND it is `#F4EEE3`. It is the tint
  of a card or a section stripe drawn on the page. One contrast pair is measured
  against it.

They are close in value and completely different in role. If the editor shows
one control for "the light colour", the therapist cannot set her page
background, and the mockup paints the wrong surface.

Both come from the direction palette and neither is derived:
`paper` ← `palette.paper`, `light_neutral` ← `palette.light`.

### Why the two surfaces never move

A contrast fix corrects the ink or a brand colour, never the surface. `paper`
carries five pairs and `light_neutral` one: darkening either to fix a single
pair silently changes every other pair drawn on it. `suggested_fix.token` is
therefore only ever `primary`, `secondary`, `accent` or `dark_neutral`.

---

## 4. Contrast

`contrast.pairs` is always these seven, always in this order.

| `pair_id` | What it means | A fix moves |
|---|---|---|
| `cta_label_on_primary` | The button's label, on the button. | `primary` |
| `dark_neutral_on_paper` | **Body text on the page.** The one that matters most. | `dark_neutral` |
| `primary_on_paper` | Links and headings on the page. | `primary` |
| `secondary_on_paper` | Supporting headings on the page. | `secondary` |
| `accent_on_paper` | Accent marks on the page. | `accent` |
| `dark_neutral_on_light_neutral` | Body text inside a tinted band. | `dark_neutral` |
| `paper_on_dark_neutral` | Inverted text in a dark section. | `dark_neutral` |

`cta_label_on_primary`'s `fg` is `cta_ink` — white where white reads on the
primary, otherwise the dark neutral darkened until it does. It used to be
"white or the dark neutral, whichever reads better", which left the pair below
AA on two shipped palettes. The backend decides; render what it returns. Nothing
changes on the client side: `fg` was always the value to paint.

> ⚠ **Three of the seven measure a text variant, not the brand colour.**
> `primary_on_paper`, `secondary_on_paper` and `accent_on_paper` measure a brand
> colour *as text*, so they measure `primary_text` / `secondary_text` /
> `accent_text` against `paper`. That is the value the mockup paints for a
> heading or a link; measuring the brand colour there was measuring a use that
> does not exist. The pair's `fg` is the variant, so rendering `fg` shows what
> was actually measured.
>
> `cta_label_on_primary` is deliberately unchanged: it is a label on a **fill**,
> and the fill is the brand colour.
>
> `suggested_fix.token` is still `primary`, `secondary`, `accent` or
> `dark_neutral` — never a derived colour. If one of those pairs ever fails, the
> brand colour moves and the variant is recomputed from it. **Neither a `*_text`
> value nor `cta_ink` can appear as a `suggested_fix.token`**; there is no
> control behind either.
>
> All six shipped palettes now reach AA on all seven pairs. The pairs that can
> still fail on a palette she edits are the neutral ones —
> `dark_neutral_on_paper`, `dark_neutral_on_light_neutral`,
> `paper_on_dark_neutral` — because `dark_neutral` *is* the ink and has no
> variant to fall back on.

`ratio` is WCAG 2.1, rounded to two decimals. `level` is derived from the
**rounded** ratio, so they can never disagree:

| `level` | ratio |
|---|---|
| `AAA` | ≥ 7 |
| `AA` | ≥ 4.5 |
| `AA_large` | ≥ 3 |
| `fail` | < 3 |

`worst_ratio` is the minimum of the seven. `passes_aa` is true only when all
seven are ≥ 4.5.

### When `suggested_fix` is null

Exactly two cases:

1. **The pair already reaches 4.5:1.** `ratio >= 4.5`. Nothing to fix.
2. **No lightness of that colour reaches 4.5:1** without leaving the band
   0.05–0.95, where the hue is gone and the result is black or white. Rare, and
   real: a hue-30 colour at 0.5 saturation tops out at 4.25:1 against a
   `#767676` background. Returning black would be a replacement, not a
   correction.

Otherwise `suggested_fix` is `{"token": …, "hex": …}` and the hex is guaranteed
to reach ≥ 4.5:1 against the other side of that pair.

A real one, from a spec whose `dark_neutral` was set to a mid grey — the case a
therapist creates, and one no derived colour rescues, because `dark_neutral`
*is* the ink:

```json
{
    "bg": "#F4EEE3",
    "fg": "#8A8A8A",
    "label": "Body text on a tinted section",
    "level": "fail",
    "ratio": 2.99,
    "pair_id": "dark_neutral_on_light_neutral",
    "suggested_fix": {
        "hex": "#6B6B6B",
        "token": "dark_neutral"
    }
}
```

`token` always names a colour she has a control for. `hex` is what to write to
it — but call `site_spec_fix_contrast` rather than patching it yourself, so the
suggestion is recomputed against the spec as it stands now.

Note that `AA_large` pairs *do* carry a fix — the target is 4.5, not 3. In the
envelope above, `cta_label_on_primary` at 4.22 and `primary_on_paper` at 3.91
are both `AA_large` and both offer one.

### Applying one

`site_spec_fix_contrast(p_brand_kit_id, p_pair_id)`. It recomputes the
suggestion rather than trusting a hex from the client, applies it, and returns
the full envelope. Calling it on a pair that already passes returns
`no_fix_needed` — it is not an error the user caused; treat it as a no-op.

**Contrast never blocks a write.** There is no CHECK on a ratio. A spec with a
failing pair saves normally. Report it, offer the button, do not gate the save.

### ⚠ A fix is not local, and it is not final

`suggested_fix` rewrites **one token**. Every pair that shares that token
changes with it. In the envelope in section 2, two pairs want the same token at
different values:

```
cta_label_on_primary  ->  primary  #AD6347
primary_on_paper      ->  primary  #A35D43
```

They cannot both be applied. Applying either one makes the other's suggestion
stale — the returned envelope carries the recomputed one.

**A previously passing pair can drop.** Measured, on OCHRE & PAPER, applying the
`primary_on_paper` fix:

| pair | before | after | |
|---|---|---|---|
| `cta_label_on_primary` | 5.23, fg `#2A2118` | 4.90, fg `#FFFFFF` | **dropped** |
| `primary_on_paper` | 2.85 | 4.62 | fixed |
| the other five | — | unchanged | |

It dropped from AA to AA and stayed above 4.5, and the button's label flipped
from the dark neutral to white because white now reads better on the darker
primary. Neither was predictable from the pair that was clicked.

So:

- **Re-render the entire `contrast` block from the returned envelope.** Do not
  patch the one pair you clicked.
- **Never show "all fixed" because one call succeeded.** Read
  `contrast.passes_aa` from the returned envelope.
- Do not cache `suggested_fix` values across a write.

### Does it converge?

Yes, on every palette this product ships, **applying the worst-failing pair
first**. Simulated across all six families, to a fixed point:

| family | fixes needed | worst ratio after |
|---|---|---|
| PLUM & BONE | 0 | 7.28 |
| CLAY & SAND | 2 | 4.55 |
| INK BLUE & CHALK | 1 | 4.51 |
| OLIVE & CHALK | 1 | 4.54 |
| OCHRE & PAPER | 1 | 4.62 |
| SLATE & BONE | 0 | 6.14 |

**The fix-all sequence worth implementing:** take the pair with the lowest
`ratio` that carries a `suggested_fix`, apply it, re-read `contrast` from the
returned envelope, repeat until `passes_aa` is true or no pair offers a fix.
Bound the loop — four iterations is generous; two was the worst case observed.

Worst-first matters. On CLAY & SAND, fixing `secondary_on_paper` (2.80) first
and then `primary_on_paper` finishes in two steps; the reverse order wastes a
write, because the first fix's suggestion is recomputed anyway.

The loop terminates because every fix moves its token toward the surface's
opposite lightness, and `paper` and `light_neutral` never move — the target is
fixed. If a pair offers no fix (section 4's second null case), stop and show the
warning; there is nothing further to apply.

---

## 5. Limits

`site_catalog()` returns both blocks. They are different numbers for different
consumers.

```json
{
  "direction_limits": {
    "name": 20, "name_words_max": 2,
    "rationale_min": 60, "rationale_max": 95,
    "hero_headline": 46, "hero_subhead": 60,
    "tone_keywords_count": 3, "tone_keywords_joined": 32,
    "directions_count": 3
  },
  "site_spec_limits": {
    "hero_overline": 48, "hero_headline": 90, "hero_subhead": 220,
    "hero_cta_label": 28, "about_excerpt": 600,
    "section_text": 800, "extra_instructions": 2000
  }
}
```

- **`direction_limits`** is read by the **generation pipeline**, to bound the
  LLM that writes `brand_kits.directions`.
- **`site_spec_limits`** is read by the **editor**, to bound what the therapist
  types into the site spec.

> ⚠ **Do not bound direction generation with `site_spec_limits`.** A direction
> headline may be 46 characters. The site spec allows 90. They are different
> because a direction is rendered three-up in a 250px mockup on the reveal
> screen, and a site spec is rendered once on a page. Generate a direction at 80
> characters and the insert is refused — after the generation has been paid for.

`section_text` (800) is the ceiling for **any** string inside a section's
`fields`, including each item of a `list`.

---

## 6. Direction generation — the new obligation

`brand_kit_palette_valid` used to return NULL for a palette missing a key, and
a CHECK constraint accepts NULL. It no longer does.

### The palette shape

Every `directions[].palette` must carry exactly these five keys:

```json
{ "primary": "#RRGGBB", "secondary": "#RRGGBB",
  "light": "#RRGGBB", "dark": "#RRGGBB", "paper": "#RRGGBB" }
```

`accent` may be added and is used when present. Any other key is ignored.
**Any missing key is refused at write time.**

In particular `{primary, secondary, accent, light_neutral, dark_neutral}` — the
shape some earlier prompt documents describe — **is refused**. It was silently
accepted until this lot, and then broke direction selection with a NOT NULL
violation deeper in the stack.

The failure you will see:

```
ERROR: new row for relation "brand_kits" violates check constraint
       "brand_kits_directions_shape_check"
```

PostgREST surfaces this as HTTP **400** with `"code":"23514"`.

### The direction length bounds

Enforced by `brand_kits_directions_rendering_check`, same 400, same class:

| field | bound |
|---|---|
| `name` | ≤ 20 characters, one or two words |
| `rationale` | 60–95 characters (both ends) |
| `hero.headline` | ≤ 46 |
| `hero.subhead` | ≤ 60 |
| `tone_keywords` | exactly 3, single words, joined with ` · ` ≤ 32 |
| the array itself | exactly 3 directions, distinct ids, **3 distinct heading fonts** |

### ⚠ Validate before the insert, and retry

The constraint fires on `INSERT`. By then the LLM call is spent.

**The generation pipeline must check the palette shape and every length bound
in application code, before writing, and retry generation a bounded number of
times when a bound is missed.** A direction that fails the CHECK after the user
has paid is a paid generation that produced nothing, and the CHECK cannot give
her anything better than a 400.

Read the bounds from `site_catalog().direction_limits` so there is one source of
truth; do not hardcode them.

---

## 7. `seed_clamped`

`spec.seed_clamped` is `null` when nothing was shortened — which is the normal
case, and the case `direction_limits` exists to make universal.

When the seeder did shorten something:

```json
{
  "hero.overline":  { "original_length": 80,  "clamped_length": 39 },
  "hero.cta_label": { "original_length": 39,  "clamped_length": 25 },
  "about_excerpt":  { "original_length": 732, "clamped_length": 600 }
}
```

**In practice only these three keys appear.** The seeder computes a clamp note
for five fields — the three above plus `hero.headline` and `hero.subhead` — but
those two are bounded upstream at 46 and 60 by
`brand_kits_directions_rendering_check`, well inside the site spec's 90 and 220,
so they cannot arrive over-long and their note cannot fire. Nothing in
`brand_kits` bounds the overline, the CTA label or the About text.

Code defensively anyway: read whatever keys are present rather than switching on
three. A brand kit written before that CHECK was tightened could in principle
carry a longer headline.

Cuts are made on a word boundary.

### It self-dismisses

Writing a field removes its own entry, and only its own. Rewrite
`hero.cta_label` and `hero.cta_label` disappears from `seed_clamped`; the other
two stay. When the last one goes, `seed_clamped` becomes `null`, not `{}`.

`site_spec_reset(…, 'copy')` re-applies the *same* clamped text, so the note
correctly survives it.

### ⚠ Show the original; do not offer to restore it

The full text is readable at
`brand_kits.directions[<selected_direction_id>].hero` and `.about_excerpt`.

**It cannot be saved back.** The limit is a CHECK, and the original is over it —
that is why it was clamped. So the note shows her what was cut and invites her
to rewrite it to fit. An "undo" button here would fail with `too_long` every
time.

---

## 8. What the frontend must never do

**No unauthenticated route.** Nothing in this feature is public. There is no
`anon` policy on `site_specs` and there must never be one. The mockup is a
design reference inside the authenticated app.

**No publish, deploy or share path.** Eklio does not host and does not build the
site. `brand_kits.share_slug` is a separate, unresolved question; this feature
does not reopen it.

**Do not recompute the preview model.** Render `preview` as it arrives. Which
pages appear, which sections, their order, and where each section's copy comes
from are design decisions the backend has already made. Two implementations
means the mockup eventually stops matching the output she is about to paste.

### ⚠ `order` is a sort key, never an index

Disabled sections are omitted from `preview` and the remaining `order` values
are **not** renumbered. From the envelope in section 2, the Services page:

```
spec.pages[services].sections     services(1)  fees(2)  faq(3, disabled)  footer(4)
preview.pages[services].sections  services(1)  fees(2)                    footer(4)
```

`order` there is `[1, 2, 4]`. It is already sorted ascending. Use it to sort, or
just render the array in the order it arrives — it is sorted by `order`, then by
`key`.

Never use `order` as an array index, a position, or a denominator. "Section 4 of
4" is wrong on that page; there are three.

In particular: the hero section's copy is `spec.hero` and the intro section's is
`spec.about_excerpt` — the backend has already resolved that into
`preview.pages[].sections[].fields`. Do not resolve it again, and do not read a
section's raw `fields` for those two types.

**Do not recompute contrast ratios.** Render `contrast` as it arrives. The
ratios are exact `numeric`, and `level` is derived from the rounded value so
they cannot disagree. A client-side float implementation will disagree on a
boundary, and the therapist will see 4.50 next to the word "fail".

**Do not let anyone edit the derived output text.** `output` is a pure function
of the spec. It is regenerated on every write and never parsed back. The copy
button copies it; there is no text area. She edits the spec, and the output
follows.

**Do not write `brand_kits.site_prompt`.** It is a cache the database refreshes
on every spec write, kept so existing consumers keep working. The arrow only
points one way.

---

## Appendix — the catalog

`site_catalog()` also returns `section_types` and `builder_targets`.

### `section_types` — eleven

```
type             label                    source             allowed_pages
hero             Hero                     spec.hero          home
intro            Introduction             spec.about_excerpt home,about
specialties      What I work with         fields             home,services
who_i_work_with  Who I work with          fields             home,about
approach         How I work               fields             home,about,services
services         Services                 fields             home,services
fees             Fees                     fields             services,contact
faq              Common questions         fields             home,services,contact
credentials      Training and licensure   fields             about
contact          Contact                  fields             home,about,services,contact
footer           Footer                   fields             home,about,services,contact
```

`source` says where a section's copy lives. `fields` means the section's own
`fields` object. `spec.hero` and `spec.about_excerpt` mean the top-level column
— render the editor's inputs for those two against `spec.hero` /
`spec.about_excerpt`, and PATCH them there.

> ⚠ **`intro` is allowed on two pages and reads one field.** Its `source` is
> `spec.about_excerpt` and its `allowed_pages` are `home` and `about`. In the
> envelope in section 2 the identical paragraph appears in both — because there
> is one value, rendered twice.
>
> Editing it changes both places. Label the input accordingly — something like
> "Your introduction — shown on Home and About" — rather than letting her think
> she is editing the Home page alone. There is no way to give the two pages
> different intro text; that is the design, not a limitation to work around.
>
> The same is structurally true of `hero` (`spec.hero`), but it is only allowed
> on `home`, so it renders once and the question does not arise.

Each entry also carries `fields` (key, label, kind ∈ `text` `longtext` `list`,
max_length), `default_enabled` and `active`.

A section placed on a page outside its `allowed_pages` is refused with
`invalid_field` on `pages`.

### `builder_targets` — seven

```
id           label              output_kind   accepts_prompt
lovable      Lovable            prompt        yes
framer       Framer             prompt        yes
v0           v0                 prompt        yes
generic      Another builder    prompt        yes
squarespace  Squarespace        setup_sheet   NO — no prompt input exists
wix          Wix                setup_sheet   NO — no prompt input exists
webflow      Webflow            setup_sheet   NO — no prompt input exists
```

`accepts_prompt` is generated from `output_kind` and cannot disagree with it.

### How the output expresses the brand colour and its text variant

Both, always, with the role in the label — because the reader is a therapist
with Squarespace open, or a builder that would happily use one hex everywhere.

**In the prompt**, nine token lines and a rule:

```
Primary — fills, buttons, bands and borders: #B4674A
Primary as text — headings and links on the page: #A35D43
Secondary — supporting surfaces and fills: #C08A3E
Secondary as text — supporting headings on the page: #92692F
Accent — small marks, rules and selected states: #6E3320
Accent as text — small highlighted words: #6E3320
Page background — the whole page sits on this: #FAF6EE
Section background — tinted bands and cards only: #F4EEE3
Dark neutral — body text: #2B2A27

The three "as text" values are the same brand colors, darkened only as far as
legibility requires. Use an "as text" value wherever the color is text. Use the
brand color for fills, bands, buttons and borders. Do not substitute one for the
other, and do not add either to the palette twice.
```

Note the accent above: brand and variant are the **same hex**, because that
accent already reads. That is normal and the line is still printed, so the
builder is never left guessing which value a role takes.

**In the setup sheet**, the variants get a step of their own — step 3, right
after the six palette colours — rather than three more swatches under "Set your
six colors". A therapist entering hexes into a palette panel needs to know which
three are alternates of which:

```
3. Add the text versions of those three colors
   These are the same three brand colors, darkened just enough to be readable
   as text on your page background. Add them alongside the others. Use them for
   headings and links; keep the brighter originals for fills, bands and buttons.
   - Primary as text — headings and links on the page: #A35D43
   - Secondary as text — supporting headings on the page: #92692F
   - Accent as text — small highlighted words: #6E3320
   > Where: Site Styles › Colors
```

⚠ **The sheet has grown twice since it was first documented — eight steps, then
nine, now eleven.** `20260829120000` added a practice-details step (step 6) and
a voice step near the end. Two of the eleven are conditional: the voice step
only when the kit has a guide, "Your own notes" only when she wrote some, and
the rest renumber to close the gap. **Do not hardcode step numbers and do not
assume a count; read `n` and render what is there.**

### The practice details step

⚠ **This step did not exist before `20260829120000`, in any form.**
`practice_details` reached the prompt's `## Practice` block and stopped there, so
a therapist following the Squarespace sheet was never once told to put her
practice name, her license or her contact details on her own site. Captured:

```
6. Fill in your practice details
   These go in your footer and on your contact page. Your name and license
   belong together wherever either appears — most boards require it.
   - Name: Elm & Ember Therapy
   - Licensed practitioner: Nora Whitfield, LCSW #LC61234
   - Location: Portland, OR
   - Email: hello@elmandember.com
   - Phone: (503) 555-0123
```

Only the details she has filled in appear. An empty `practice_details` omits the
step's values entirely rather than printing empty labels.

### The button step, and the size floor

It carries the label, the link, the ink and a minimum size:

```
8. Point the button at your booking link
   - Button label: Book a consult
   - Button links to: https://elmandember.clientsecure.me/book
   - Button label color: #10100F
   - Smallest the label may be set: 24px, or 19px if bold
```

The same floor is a **sixth constraint** in the prompt — the constraints block
now emits six lines, not five:

```
- Do not set the call-to-action label below 24px, or 19px if it is bold. The
  button's two colors were checked for text at that size; keep the label at or
  above it and the pair stays legible.
```

⚠ It is there because the deliverable makes a claim about rendered size the
moment it tells a builder to put a label on a button, and neither Eklio nor the
builder can check what size a template actually renders it at. If your editor
shows a button preview, render it at or above that floor.

> ⚠ **The numbers changed at `20260829121000`, and the old ones were wrong.**
> The floor shipped as `18px bold, or 24px if it is not bold`. WCAG's large-text
> threshold is **18.66px** bold (14pt) or 24px regular (18pt), so 18px bold sat
> *below* the threshold the `cta_label_on_primary` measurement assumes — the
> instruction could not deliver what it implied, and you were right to refuse to
> tell her otherwise. It is now `24px, or 19px if bold`: 19 clears 18.66 with a
> whole pixel, which is also a number a person can type into a size box without
> arguing about rounding. **Following the instruction now keeps the button
> legible at the level the contrast check assumed.** Nothing else moved — no
> pair was re-measured and no colour changed; the floor has always been copy,
> which is why it lives in `site_output_templates`.

`output.kind` follows: `"prompt"` gives `{kind, text, char_count}`;
`"setup_sheet"` gives `{kind, steps[], copy_blocks[]}` where each step is
`{n, title, body, values[], builder_hint}` and each copy block is
`{page, section, label, text}`.

Squarespace, Wix and Webflow have no box to paste a prompt into. Do not offer
one. Render the sheet.
