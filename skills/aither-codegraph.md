# aither-codegraph — a call-graph-aware code index your agents can query

Grep finds strings; **CodeGraph** finds *structure*. It parses a codebase into chunks
(functions, classes, routes) with a real **call graph** — who calls what, who's affected
by a change — and lets an agent ask "where is auth enforced?" and get the symbol, its
signature, its callers, and its callees. It's the difference between an agent that greps
and one that understands the code.

Two ways to run it: **adk-native** (self-hoster, one command) and the **fleet service**
(the managed `aitheros-cognition-advanced` graph with MCP tools).

## adk-native — index your own codebase in one command

`adk` auto-indexes a Python project when you run it there and attaches two tools to your agent:

```bash
pip install aither-adk
cd /path/to/your/python/project
adk run            # detects Python → "Indexing N files... M chunks in Xs" → tools attached
adk chat           # now ask: "where is rate limiting enforced?"
```

Your agent gains:
- **`code_search(query, max_results=10)`** — natural-language/keyword search → chunks with
  `name`, `type`, `file`, `line`, `signature`, `calls`, `called_by`.
- **`code_context(chunk_id)`** — full context for a chunk: signature, docstring, callers,
  callees, and the source body.

Programmatically (build it into your own agent):

```python
from adk.faculties.code_graph import CodeGraph
cg = CodeGraph()
stats = await cg.index_codebase("/path/to/repo")   # {'total_chunks': ..., 'total_files': ...}
agent.set_code_graph(cg)                            # registers code_search + code_context
```

Re-run `index_codebase()` (or `adk run`) after significant changes — the index is a snapshot,
not live.

## Fleet service — the managed CodeGraph (`aitheros-cognition-advanced:8153`)

In an AitherOS fleet, CodeGraph is a router on the `aitheros-cognition-advanced` compound
service (port **8153**, path `/codegraph`), persisted under `Library/Data/codegraph` (an
`index.json` + embeddings). It's in the default `core` profile.

**Configure / mount a repo to index** (compose):
```yaml
# docker-compose: give the service your repo read-only
volumes:
  - /path/to/your/repo:/host/external/your-repo:ro
# env
AITHER_CODEGRAPH_URL: https://aitheros-cognition-advanced:8153   # override discovery
AITHER_CODEGRAPH_RECONCILE: "0"                                  # off = no disk-storm reindex
```

**HTTP API** (behind the internal CA):
```bash
POST /codegraph/index         {"root_path":"/host/external/your-repo","force":false}   # (re)index
GET  /codegraph/search?q=...                                                           # search
GET  /codegraph/context/{chunk_id}                                                     # callers/callees
GET  /codegraph/chunk/{chunk_id}/code                                                  # exact source
GET  /codegraph/stats                                                                  # index size
GET  /codegraph/impact/{symbol}                                                        # blast radius
GET  /codegraph/impact-commit/{sha}                                                    # commit blast radius
```

**MCP tools** (exposed on the AitherNode gateway — agent-callable):
`codegraph_search`, `codegraph_context`, `codegraph_get_code`, `codegraph_trigger_index`,
`codegraph_explore`, `codegraph_impact`, `codegraph_affected_tests`, `codegraph_impact_commit`,
`codegraph_routes`, `codegraph_get_stats`.

**Keep it fresh:** there is no auto-reindex by default — call `codegraph_trigger_index`
(or `POST /codegraph/index`) after changes, or wire it to a routine/CI step.

## Pair it with Prospector (find the dirs first)

CodeGraph is precise but indexes everything. On a big repo, narrow the search *first* with the
[`aither-prospector`](aither-prospector.md) file-explorer — `map_localize("where is auth?")`
returns the handful of dirs to look in, then let CodeGraph resolve the exact symbols and call
graph inside them. Localize → search → trace.

## Part of one substrate

CodeGraph is the code-structure layer under [aither-adk](aither-adk.md); pair it with
[graph-rag-agent](graph-rag-agent.md) (knowledge over your *docs*) and
[aither-prospector](aither-prospector.md) (semantic *file-explorer*) for an agent that knows
both your code and your knowledge. MIT-licensed, like everything in `aither-skills`.
