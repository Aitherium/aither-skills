---
allowed-tools: Read, Grep, Glob, Bash, PowerShell, Edit
description: Review auth, tenancy, entitlement and cache-sharing code against six fail-closed defect classes that ruff and mypy cannot see — four checked mechanically by the bundled security_lint.py, three semantic ones you read against the diff. Every class was a real bug caught by review, not by lint.
argument-hint: [<changed files> | --all | --explain]
---

# Fail-Closed Authz Review

Linters check style. These six classes are **semantic** — the code is well-formed,
typed, and lint-clean, and it hands an attacker another tenant's data.

Every one below was a real, shipped bug found by adversarial review. Run this on any
change touching authentication, tenancy, entitlements, capability tokens, KV/cache
sharing, or any cross-tenant boundary.

```bash
python tools/security_lint.py <changed files>     # mechanical subset, exit 1 on ERROR
python tools/security_lint.py                     # scan default auth/tenancy globs
SECURITY_LINT_GLOBS='src/auth/**/*.py' python tools/security_lint.py
python tools/security_lint.py --selftest          # prove the linter itself works
```

**Zero ERRORs required.** Then read the three semantic classes against the diff by
hand — the tool cannot see them, and they are the ones that cost the most.

---

## The four mechanical classes (`security_lint.py` catches these)

### SEC001 — `verify=False` on a TLS call
Disabling certificate verification to talk to an internal service means anything on
the network path can impersonate it. Trust your internal CA instead — install the CA
bundle and pass it, don't turn verification off.

### SEC002 — Fail-OPEN gate
**A security decision function must DENY on every error, `None`, empty, and default
path.** The tool flags any function whose name marks it a gate (`*gate*`, `*entitl*`,
`*owns*`, `*authz*`, `*allow*`, `*_ok`, `is_*`, `verify_*`, `check_*`, `require_*`)
that returns a truthy value out of an `except` handler.

```python
# ❌ an exception ALLOWS
def check_tenant_access(user, tenant_id):
    try:
        return user.tenant_id == tenant_id
    except Exception:
        return True

# ✅ every non-happy path denies
def check_tenant_access(user, tenant_id):
    try:
        return bool(user and user.tenant_id == tenant_id)
    except Exception:
        return False
```

### SEC003 — Fabricated-platform / absent-caller auto-trust
Many frameworks synthesise a "system" or "platform" caller when no caller context is
set. Treating that as privileged means **an unauthenticated request that reaches the
code without auth middleware is trusted.** Exempt only genuine privilege (a real admin
role); absent or anonymous caller must deny.

### SEC004 — Inert fail-soft return
A function that returns an empty collection on failure *and* a populated one on
success gives the caller no way to tell "no data" from "broken". Add a `degraded` flag
or an `error` key. This is the warning that most often turns out to be a real outage
hiding as an empty dashboard.

---

## The three semantic classes (you must read for these)

### 1. Trusting caller-supplied input for an authz decision
The request payload is **caller-influenceable** — `metadata`, `extra_metadata`,
`messages`, a `source` / `user_id` / `tenant_id` body field. Never key a security
decision on it.

```python
# ❌ the boundary is drawn with the attacker's own numbers
tenant_id = request.json["tenant_id"] or "default"
if doc.tenant_id != tenant_id: deny()

# ✅ derive identity from the AUTHENTICATED caller, then check the CLAIM against it
identity = get_current_caller()          # verified token / session
if identity is None: deny()
if request.json.get("tenant_id") not in (None, identity.tenant_id): deny()
```

This one shipped a **cross-tenant document read** reachable with zero credentials —
and the same endpoint correctly refused when the body fields were *omitted*, so the
gate worked fine and was simply asked the wrong question.

### 2. Missing internal auth on service-to-service calls
An internal POST with no service-identity header 401s and fails **silently** when it's
fire-and-forget telemetry; the read path then returns `[]` and looks like "working but
empty." Send the credential and prove a positive round-trip live.

### 3. Silent no-op — "everything returns empty" looks like it works
A fail-closed path that *always* returns empty passes every "returns nothing"
assertion trivially. **A test suite that only asserts denials is blind to a totally
inert feature.** Every feature needs a positive assertion that the happy path really
returns data, proven live rather than unit-mocked.

Watch for identity-mismatch no-ops: a value registered under one key (hostname) and
looked up under another (pool id) silently matches zero rows forever.

### Bonus — key-scope confusion
Cache and content-addressed keys must be tenant-first — `(tenant, workspace, hash)` —
so a same-hash collision across tenants never matches. Verify the cross-tenant lookup
returns nothing in a **live** test. And a hash computed from untrusted input can forge
a key, so gate the *use* of the key on authenticated ownership, not on the key itself.

---

## How to run this review

1. `python tools/security_lint.py <changed files>` — must be zero ERRORs.
2. Read each of the three semantic classes against the diff and **state which you
   checked**. "I reviewed it" is not a check; naming the class against the code is.
3. For anything that gates access, find the test that proves the **allow** path
   returns real data. If it does not exist, the feature is unverified regardless of
   how many denial tests pass.
4. A change that trips any of these is not done.

## Known limits — say these out loud

- The tool is AST-based and **name-driven**: it finds gates by naming convention, so a
  security decision in a function called `process()` is invisible to it. The naming
  convention is itself part of the standard.
- SEC003 fires on *any* branch comparing to `"platform"`, including legitimate ones.
  It is a WARN for that reason — triage, don't suppress.
- Passing a path that does not exist **aborts with exit 2** rather than reporting a
  clean run. That behaviour exists because the earlier version silently skipped
  unreadable paths and printed "0 error(s)" — a linter with the exact defect it lints
  for. If you wire this into CI, treat exit 2 as a failure, not a pass.
