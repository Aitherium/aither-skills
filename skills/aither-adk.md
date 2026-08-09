# aither-adk — run your own AI agent, on your machine, in three commands

[aither-adk](https://github.com/Aitherium/aither-adk) is the agent toolkit: an agent runtime, a
local shell, inference setup, and control-plane enrollment in one package. You run the model, the
agent loop, the memory, and your data **on your own box** — Aitherium hosts only the control plane,
and you manage everything from `portal.aitherium.com`. Nothing about your inference or data leaves
your machine.

## Set it up

```bash
pip install aither-adk          # the whole toolkit — already on PyPI
adk onboard --quick             # detect hardware, stand up inference, install a pack, enroll
adk run --agents openclaw       # run an agent locally
```

`curl -fsSL https://aitherium.com/install.sh | sh` bootstraps the toolkit without a Python of your own.
After install, add an agent pack:

```bash
adk install pack:openclaw       # or hermes / claude-code
```

Verify it:

```bash
adk doctor                      # confirms toolkit, packs, and inference are ready
```

`adk onboard --quick` runs `adk quickstart-local`: it detects your CPU/RAM/GPU, picks a backend
(**Ollama**, **llama.cpp**, or **vLLM**), pulls and serves a model, and verifies it. Prefer a hosted
model? Skip local inference and set a key instead:

```bash
adk keys set anthropic <your-api-key>   # or openai / deepseek / openrouter / groq / together / google
```

## Use it

```bash
adk up                          # one command: stand up a persistent agent (hosted-brain default)
adk run --agents openclaw       # run a specific bundled pack (openclaw / hermes / claude-code)
adk chat                        # talk to your agent from the terminal
adk install pack:openclaw       # add an agent pack
adk pack customize openclaw --system-prompt "You are my focused research assistant."
adk doctor                      # check inference, packs, enrollment, and mesh health
```

Pack customization is written to an overlay (`~/.aither/agents/<pack>/agent.yaml.local`) — your
edits survive pack updates and never touch the shipped pack.

## Log in & enroll (optional, for the portal + fleet)

```bash
adk login          # device-flow auth — you approve in the browser, no password typed into the CLI
adk enroll         # register this workstation (hardware + models) to your account
```

Then open **portal.aitherium.com → Workstation** to see your node and wire in your own tools. BYO /
self-hosted nodes are uncapped by default — caps only apply on the metered hosted gateway.

## Part of one substrate

aither-adk is the runtime the rest plug into: stand up hardware as an [AitherNode](aithernode.md),
wire it to the control plane with [AitherConnect](aitherconnect.md), provision the box with
[AitherZero](aitherzero.md), and pool compute across machines with
[OmniNode](omninode-node.md) over AitherMesh. Standing up compute and having your agents use it
should be one motion, not five projects.

MIT-licensed, like everything in `aither-skills`.
