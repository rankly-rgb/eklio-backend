#!/usr/bin/env python3
"""
Compare a fingerprint of the replayed schema against the recorded production one.

⚠ THE QUESTION IS "DOES THIS REPOSITORY DESCRIBE THE DATABASE?"

Everything written this month is a guarantee about a schema built by replaying
`supabase/migrations`. Where production is not that schema, those guarantees
are about a different database. `direction_asset_daily_spend` (RLS on in
production, off in a replay) was the first divergence found; this exists to
answer whether it was the only one.

Reads two files of `kind|identity|fingerprint` lines and prints three lists:

  ONLY IN PRODUCTION   the database has it, the migrations do not produce it
  ONLY IN THE REPLAY   the migrations produce it, the database does not have it
  DIFFERENT            both have it and they are not the same

Usage:  schema_drift_report.py <production.txt> <replay.txt>
Exits 1 when anything diverges. A drifted schema is a failure, not a warning.
"""
import os
import sys


def load(path):
    """kind|identity -> fingerprint. The identity may itself contain '|'
    (function signatures do not, but a default expression could), so the
    fingerprint is split off the RIGHT."""
    out = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            # Blank lines and the header comment are not schema objects.
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            key, _, fingerprint = line.rpartition("|")
            out[key] = fingerprint
    return out


def load_accepted(path):
    """kind|identity|prod|replay -> reason, pour les divergences déjà lues.

    ⚠ LE TRIPLET, PAS L'IDENTITÉ. Exempter « cette fonction » laisserait son
    contenu changer des deux côtés sans que rien ne rougisse. Exempter « cette
    fonction, avec CETTE empreinte de production et CETTE empreinte de rejeu »
    ne laisse passer que l'écart qui a été lu : dès qu'un des deux côtés bouge,
    le triplet ne correspond plus et la divergence est comptée.
    """
    accepted = {}
    if not path or not os.path.exists(path):
        return accepted
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split("|")
            if len(parts) < 4:
                continue
            prod_fp, replay_fp = parts[-2], parts[-1]
            key = "|".join(parts[:-2])
            accepted[(key, prod_fp, replay_fp)] = raw.split("#", 1)[1].strip() if "#" in raw else ""
    return accepted


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__)
        return 2

    production = load(sys.argv[1])
    replay = load(sys.argv[2])

    # ⚠ ANTI-VACUOUS. An empty or truncated side would make every list below
    # empty, which reads exactly like "no drift" — the worst possible green.
    for name, side in (("production", production), ("replay", replay)):
        if len(side) < 1000:
            print(f"REFUSING TO COMPARE: the {name} side has only {len(side)} "
                  f"objects. Something truncated it; this is not a clean schema.")
            return 2

    only_production = sorted(set(production) - set(replay))
    only_replay = sorted(set(replay) - set(production))
    different_all = sorted(k for k in set(production) & set(replay)
                           if production[k] != replay[k])

    # ⚠ THE `.env` KINDS ARE THE SERVER, NOT THE SCHEMA.
    #
    # `grant.table.env` and `grant.function.env` carry the parts of an ACL that
    # no migration in this repository grants and that differ between a hosted
    # PostgreSQL 17 and a local 16: the MAINTAIN privilege, the REFERENCES /
    # TRIGGER / TRUNCATE that Supabase's default privileges hand out, and the
    # EXECUTE that `supabase_admin` holds on extension functions. Before the
    # split they produced 96 differences, every one of them false, and they
    # buried the three that were real.
    #
    # They are PRINTED — a privilege nobody can see is a privilege nobody can
    # audit — and they do not count towards the exit status. An object that
    # exists on one side only still fails, through its own non-.env rows: this
    # softens the READING of a shared object's ACL, never the question of
    # whether the object is there.
    def is_env(key):
        return key.split("|", 1)[0].endswith(".env")

    different_schema = [k for k in different_all if not is_env(k)]
    different_env = [k for k in different_all if is_env(k)]

    # ⚠ LES DIVERGENCES DÉJÀ LUES, ET SEULEMENT CELLES-LÀ.
    #
    # Le fichier par défaut est schema_drift_accepted.txt, à côté de celui-ci.
    # Une divergence n'y est reconnue que si son identité ET ses deux empreintes
    # correspondent : c'est ce qui fait qu'une des quarante-sept qui changerait
    # rougirait, au lieu d'être couverte par une exception qui ne sait pas ce
    # qu'elle exempte.
    accepted_path = (sys.argv[3] if len(sys.argv) == 4
                     else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "schema_drift_accepted.txt"))
    accepted = load_accepted(accepted_path)
    matched = [k for k in different_schema
               if (k, production[k], replay[k]) in accepted]
    different = [k for k in different_schema if k not in set(matched)]

    # ⚠ ANTI-VACUITÉ, DANS L'AUTRE SENS. Une exemption qui ne correspond plus à
    # rien est une exemption périmée : l'objet a changé, ou il a disparu. La
    # taire laisserait le fichier grossir en silence jusqu'à ne plus décrire
    # aucune des divergences réelles.
    stale = [k for k in accepted
             if k[0] not in production or k[0] not in replay
             or production[k[0]] != k[1] or replay[k[0]] != k[2]]

    print(f"production objects: {len(production)}")
    print(f"replay objects:     {len(replay)}")
    print("")

    def section(title, keys, detail=None):
        print(f"== {title}: {len(keys)} ==")
        for key in keys:
            print(f"  {key}" + (f"   {detail(key)}" if detail else ""))
        if not keys:
            print("  (none)")
        print("")

    section("ONLY IN PRODUCTION (the migrations do not produce it)", only_production)
    section("ONLY IN THE REPLAY (the database does not have it)", only_replay)
    section("DIFFERENT", different,
            lambda k: f"prod={production[k][:8]} replay={replay[k][:8]}")
    section("ENVIRONMENT, NOT SCHEMA (printed, not counted -- see the .env note "
            "in schema_fingerprint.sql)", different_env,
            lambda k: f"prod={production[k][:8]} replay={replay[k][:8]}")
    section("ALREADY READ AND ACCEPTED (identity AND both fingerprints matched "
            "-- schema_drift_accepted.txt)", matched,
            lambda k: accepted[(k, production[k], replay[k])])

    if stale:
        print(f"== STALE EXEMPTIONS: {len(stale)} ==")
        print("  Ces lignes de schema_drift_accepted.txt ne correspondent plus à")
        print("  aucune divergence réelle : l'objet a changé ou disparu. Les")
        print("  relire, ou les retirer -- une exemption périmée cache la")
        print("  divergence suivante.")
        for key, prod_fp, replay_fp in sorted(stale):
            print(f"  {key}   prod={prod_fp[:8]} replay={replay_fp[:8]}")
        print("")

    total = len(only_production) + len(only_replay) + len(different) + len(stale)
    print(f"TOTAL DIVERGENCES: {total}"
          + (f"   (+{len(different_env)} environmental, "
             f"+{len(matched)} already read, not counted)"
             if different_env or matched else ""))
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
