# The symptom names the innocent — follow the wire, not the error text
*Part II · Silence*

**Fires when:** an error message names a component. Especially when it names one
you already distrust.

## The law

Error text is written by the *caller*, at the moment it gives up. It names what
the caller was trying to do, which is very often not what actually broke. Treat
the name in the message as a hypothesis with no evidence behind it.

## Four cases, each of which cost a session

**An identity service that was healthy the whole time.** Four call sites read a
URL as `os.environ.get("IDENTITY_URL", get_service_url("events"))` — the default
pointed at the event bus, which serves no auth routes. So the login endpoint and
both halves of a device grant went to a service that could not possibly answer.
Each proxy folded the failure into its own generic "identity service unavailable".
**Identity answered a direct probe with a real device code while every surface
reported it down**, and no log line anywhere mentioned the event bus.

**A CI job that said the API was down.** A self-hosted job probed `https://` at a
host-published port terminated by a load balancer that speaks plain HTTP. Measured:
`http` = 200, `https` = handshake failure. The job retried 12 times and printed
`##[error]API is not running` — **while the API was healthy throughout.**

**A decompressor named in a traceback that was never selected.** A checkpoint
failed to load with an assertion inside one quantisation format's decompressor.
The format resolution was entirely correct; that class merely *inherited*
`decompress` from a sibling. Four hypotheses died on the coincidence. The real
defect was a pattern list that matched none of the module names present — a
question answerable from the config file in 200ms, on no hardware. The wrong
reading cost **42.5 hours of rented 8-GPU time and produced 48 bytes.**

**A maintenance page.** A public login served "both identity nodes are
reconnecting". Both identity nodes were healthy. The 502 came from a routing rule
pointing at an origin over the wrong scheme, folded into a *designed* error page
whose text named the innocent service by hand.

## Why this shape is so common

A generic fallback message is written once, early, by someone who imagined only
one failure mode. Then every other failure gets routed into it. The message ages
into a lie that reads as a diagnosis.

## The check

When an error names a component, do these in order and stop at the first
surprise:

1. **Probe the named component directly**, with the same scheme, port and header
   the caller uses. If it answers, the caller is wrong about who it is talking to.
2. **Read the caller's resolved target** — not the config, the *value at runtime*.
   Env-var defaults and fallback chains are where this lives.
3. **Check the scheme.** Plain HTTP into a TLS listener closes the socket and
   reads as "the service is down". TLS into a plain listener hangs. Neither error
   names the scheme.

And when you write the message, name what you *called*, not what you assume it
was: `POST https://auth-host:9443/auth/device -> connection refused` is a diagnosis.
"Identity unavailable" is a guess someone else will inherit.
