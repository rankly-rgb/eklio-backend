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


def main():
    if len(sys.argv) != 3:
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
    different = sorted(k for k in set(production) & set(replay)
                       if production[k] != replay[k])

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

    total = len(only_production) + len(only_replay) + len(different)
    print(f"TOTAL DIVERGENCES: {total}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
