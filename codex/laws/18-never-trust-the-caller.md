# Never trust the caller for an authorization decision — the payload is not evidence
*Part V · Trust*

**Fires when:** any code decides *who* someone is, or *what* they may reach.

## The law

Derive identity and scope from the **authenticated** caller — the verified token,
the session, the middleware-established context. Then check the request's claimed
target against that.

Never from the request body. Never from a metadata field. Never from a `source=`
string, a header the client can set, or an id extracted from the messages.

```python
# wrong - the caller chose this value
tenant = payload["metadata"]["tenant_id"]

# right - the caller proved this value
caller = get_current_caller()
if payload["tenant_id"] != caller.tenant_id and not caller.is_admin:
    raise Forbidden
```

## The variant nobody expects: the fabricated caller

Many frameworks synthesise a default context when none is set — a "system" or
"platform" caller — so internal code can run without a session. If any gate then
reads:

```python
if caller.type == "platform":
    return True
```

…every unauthenticated request that reaches that code **without passing through
auth middleware** is trusted. The absence of a caller has been converted into
maximum privilege.

Exempt only *genuine* privilege — a real admin role on a real verified identity.
An absent or anonymous caller must deny.

## Content-addressed keys are an authorization decision too

A cache key, a content hash or a derived id **is** a scope decision:

- Key tenant-first — `(tenant, workspace, hash)` — so an identical hash in two
  tenants can never collide into a shared read. Prove it with a live cross-tenant
  lookup that returns nothing.
- A hash computed from untrusted input can be *forged*. Gate the **use** of the
  key on authenticated ownership, not on possession of the key.

## Where the boundary really is

Two related mistakes worth naming, because both look like tidying up:

**"It's an internal call, so it's fine."** A route reached by an in-process call
bypasses its own dependency-injected auth. Three "obvious" fixes to undefined
names in one audit pointed at real handlers whose authentication would have been
skipped that way — the mechanical fix would have opened a hole that a crash was
accidentally closing.

**"The app already checked."** Application permission and platform identity are
two different questions. A user can hold a perfectly valid platform session and
be a viewer in the app, or vice versa. Do not let one answer the other.

## The check

Static rules catch some of it:

```
SEC004  an authz decision keyed on a payload-supplied tenant/user/workspace id
SEC005  a fabricated/absent caller treated as privileged
```

The rest is a review question. On any diff touching auth, tenancy, entitlements,
capability tokens or a cross-tenant boundary, state which of these you checked:

1. does every error path deny? ([LAW 17](17-fail-closed-then-prove-the-happy-path.md))
2. is any decision keyed on caller-supplied input?
3. is an absent caller treated as privileged?
4. does every internal call carry an identity, over TLS you actually verify?
5. is there a positive, live assertion that the happy path returns data?
6. are cache and content keys scoped tenant-first?

A change that trips any of these is not done.
