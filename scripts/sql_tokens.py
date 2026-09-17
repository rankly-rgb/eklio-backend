#!/usr/bin/env python3
"""A real PostgreSQL lexer, used to decide what a difference between two
function definitions actually IS.

⚠ WHY THIS EXISTS RATHER THAN THE REGEX IN schema_fingerprint.sql.

That file strips comments with three `regexp_replace` calls and says so itself:
the normalisation is approximate and approximate IN THE UNSAFE DIRECTION,
because it removes `--` and `/* */` without knowing whether they sit inside a
string literal. A function whose body contains the literal text '--' would be
normalised wrongly and could be made to look EQUAL when it is not. Its own
header forbids using it to dismiss a difference; only to explain one already
found.

So when forty-one function definitions differ between production and a replay
while their normalised bodies match, "it is only a comment" is a guess. This
module turns it into a decision:

  - `tokens(sql)` walks the text character by character, honouring line
    comments, NESTED block comments (PostgreSQL nests them, unlike C),
    single-quoted strings with '' escapes, E'' escape strings with backslash
    escapes, dollar-quoted strings with arbitrary tags, and double-quoted
    identifiers with "" escapes. Comments are dropped. Everything else is kept
    VERBATIM, including the contents of every literal.

  - two definitions with the same token stream differ only in comments and
    whitespace. That is a proof, not an impression: nothing inside a literal
    was ever removed.

  - two definitions with different token streams differ in what they DO, and
    `first_divergence` says where.

Usage: sql_tokens.py <a.sql> <b.sql>   ->  prints the verdict and the first
differing token pair, exit 0 if the token streams are equal.
"""
import sys


def tokens(sql):
    """Token stream with comments removed and whitespace collapsed."""
    out = []
    i, n = 0, len(sql)
    buf = []

    def flush():
        if buf:
            out.append(''.join(buf))
            buf.clear()

    while i < n:
        c = sql[i]

        # ── line comment ────────────────────────────────────────────────
        if c == '-' and sql.startswith('--', i):
            flush()
            j = sql.find('\n', i)
            i = n if j < 0 else j + 1
            continue

        # ── block comment, NESTED (PostgreSQL, not C) ───────────────────
        if c == '/' and sql.startswith('/*', i):
            flush()
            depth, i = 1, i + 2
            while i < n and depth:
                if sql.startswith('/*', i):
                    depth += 1; i += 2
                elif sql.startswith('*/', i):
                    depth -= 1; i += 2
                else:
                    i += 1
            continue

        # ── dollar-quoted string: $tag$ ... $tag$ ───────────────────────
        if c == '$':
            j = i + 1
            while j < n and (sql[j].isalnum() or sql[j] == '_'):
                j += 1
            if j < n and sql[j] == '$':
                tag = sql[i:j + 1]
                end = sql.find(tag, j + 1)
                end = n if end < 0 else end + len(tag)
                flush()
                out.append(sql[i:end])
                i = end
                continue

        # ── single-quoted string, with E'' backslash escapes ────────────
        if c == "'" or (c in 'eE' and sql.startswith("'", i + 1)):
            start = i
            escapes = c in 'eE'
            i += 2 if escapes else 1
            while i < n:
                if escapes and sql[i] == '\\':
                    i += 2
                    continue
                if sql[i] == "'":
                    if sql.startswith("''", i):
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            flush()
            out.append(sql[start:i])
            continue

        # ── double-quoted identifier ────────────────────────────────────
        if c == '"':
            start = i
            i += 1
            while i < n:
                if sql[i] == '"':
                    if sql.startswith('""', i):
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            flush()
            out.append(sql[start:i])
            continue

        # ── whitespace ends a token ─────────────────────────────────────
        if c.isspace():
            flush()
            i += 1
            continue

        # ── word characters accumulate; anything else is its own token ──
        if c.isalnum() or c == '_':
            buf.append(c)
        else:
            flush()
            out.append(c)
        i += 1

    flush()
    return out


def function_tokens(definition):
    """Token stream of a `pg_get_functiondef` result, with the BODY lexed too.

    ⚠ THE BODY IS CODE, NOT DATA, AND THIS IS THE WHOLE DIFFICULTY.

    `pg_get_functiondef` returns `... AS $function$ <source> $function$`. To
    PostgreSQL that dollar-quoted run is one string literal, so `tokens()`
    keeps it verbatim — correctly, because for any other dollar-quoted string
    its contents are data and a difference inside it is a real difference.

    For the body it is the opposite: the comments a reader cares about live
    INSIDE it, and a definition that differs only there differs only in prose.
    So exactly one dollar-quoted token is opened: the one the top-level `AS`
    introduces. Every other one — a `$$ ... $$` nested inside the body, a
    dollar-quoted literal in a default expression — stays opaque, which errs
    towards reporting a difference rather than hiding one.
    """
    toks = tokens(definition)
    for i, t in enumerate(toks):
        if t.upper() != 'AS' or i + 1 >= len(toks):
            continue
        body = toks[i + 1]
        if not (body.startswith('$') and len(body) > 1):
            continue
        tag_end = body.find('$', 1)
        if tag_end < 0:
            continue
        tag = body[:tag_end + 1]
        if not body.endswith(tag):
            continue
        inner = body[len(tag):-len(tag)]
        return toks[:i + 1] + ['<body>'] + tokens(inner) + toks[i + 2:]
    return toks


def first_divergence(a, b):
    for k, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return k, x, y
    if len(a) != len(b):
        k = min(len(a), len(b))
        return k, (a[k] if k < len(a) else None), (b[k] if k < len(b) else None)
    return None


# ── the lexer's own probes ──────────────────────────────────────────────
#
# ⚠ EACH ONE MUST BITE. Three of them are the exact case the regex in
# schema_fingerprint.sql gets wrong — `--`, `/* */` and a dollar quote INSIDE a
# string — and they are here so that a lexer rewritten for speed one day cannot
# quietly regain the failure this module exists to remove. `--self-test` runs
# them; scripts/local-verify.sh runs `--self-test`.
_W = ("CREATE OR REPLACE FUNCTION public.f()\n RETURNS int\n LANGUAGE sql\n"
      "AS $function$\n%s\n$function$\n")

_PROBES = [
    # (a, b, expected-equal, what it guards)
    ("a -- b\nc", "a c", True, "line comment"),
    ("a /* x /* y */ z */ b", "a b", True, "NESTED block comment"),
    ("select '--x'", "select '--y'", False, "-- INSIDE a string"),
    ("select '/* x */'", "select '/* y */'", False, "/* */ INSIDE a string"),
    ("select $q$ -- z $q$", "select $q$ -- w $q$", False, "dollar quote holding --"),
    ("select 'it''s'", "select 'it''s'", True, "doubled quote"),
    ("select E'a\\'b'", "select E'a\\'b'", True, "E'' with a backslash"),
    ('select "a--b"', 'select "a--c"', False, "quoted identifier"),
    ("a\n\n  b", "a b", True, "whitespace"),
]

_FN_PROBES = [
    (_W % "  select 1", _W % "  -- a comment\n  select 1", True, "comment IN the body"),
    (_W % "  select 1", _W % "  /* block */ select 1", True, "block IN the body"),
    (_W % "  select 1", _W % "  select 2", False, "different code"),
    (_W % "  select '--x'", _W % "  select '--y'", False, "-- in a STRING in the body"),
    (_W % "  select '/*x*/'", _W % "  select '/*y*/'", False, "/* */ in a string in the body"),
    (_W % "  select $q$--a$q$", _W % "  select $q$--b$q$", False, "nested dollar quote stays opaque"),
    (_W % "select 1", _W.replace('RETURNS int', 'RETURNS bigint') % "select 1", False, "different signature"),
]


def self_test():
    bad = 0
    for fn, probes, label in ((tokens, _PROBES, 'tokens'),
                              (function_tokens, _FN_PROBES, 'function_tokens')):
        for a, b, same, what in probes:
            got = fn(a) == fn(b)
            if got != same:
                bad += 1
                print(f"  FAILED  {label}: {what} -- expected "
                      f"{'equal' if same else 'different'}, got "
                      f"{'equal' if got else 'different'}")
    n = len(_PROBES) + len(_FN_PROBES)
    print(f"  sql_tokens self-test: {n - bad}/{n} probes hold"
          + ("" if not bad else f"  -- {bad} FAILED"))
    return 1 if bad else 0


def main():
    if len(sys.argv) == 2 and sys.argv[1] == '--self-test':
        return self_test()
    a, b = (open(p).read() for p in sys.argv[1:3])
    ta, tb = function_tokens(a), function_tokens(b)
    d = first_divergence(ta, tb)
    if d is None:
        print(f"COMMENT/WHITESPACE ONLY  ({len(ta)} tokens, identical)")
        return 0
    k, x, y = d
    print(f"BEHAVIOURAL  (token {k} of {len(ta)}/{len(tb)}): {x!r} vs {y!r}")
    print("  ...a: " + ' '.join(ta[max(0, k - 6):k + 6]))
    print("  ...b: " + ' '.join(tb[max(0, k - 6):k + 6]))
    return 1


if __name__ == '__main__':
    sys.exit(main())
