# aitherzero — provision any machine from one config file and a bootstrap script

AitherZero is the self-service provisioning surface: a **`config.psd1`** plus **`bootstrap.ps1`**
that can stand up bare-metal, on-prem, cloud, or hybrid infrastructure by driving a library of
numbered PowerShell automation-scripts and playbooks. Anyone with connectivity, credentials, and a
machine runs `bootstrap.ps1` against a `config.psd1` and gets a fully provisioned environment. It
runs on **PowerShell 7** everywhere (Windows, and bootstrapped into Linux/macOS/WSL2), so the same
scripts work on every node.

## Set it up

```powershell
# from a clone of the repo, on any machine with pwsh 7:
Import-Module ./.PRODUCTS/.AITHERZERO/AitherZero.psd1     # load the environment
./bootstrap.ps1 -Playbook genesis-bootstrap              # provision using a playbook
```

`bootstrap.ps1` layers config so you only override what you need:
`base < platform (windows/linux/macos) < domain < config.local.psd1 < AITHERZERO_* env vars`.
You write a small **`config.local.psd1`** with just your overrides; everything else comes from the
defaults.

## Build your config without hand-editing psd1

The config is **generated from the script inventory** — every automation-script's `param()` block
becomes a setting — so the surface is extensible: write a PowerShell script with a `param()` block
and it extends AitherZero automatically. Two tools make this self-service:

```powershell
# 1. generate the schema from whatever inventory you point it at (public OR your private scripts)
pwsh .PRODUCTS/.AITHERZERO/tools/config-editor/Export-AitherConfigSchema.ps1 `
     -ScriptRoot <your automation-scripts> -PlaybookRoot <your playbooks>

# 2. open the visual Config Builder (tools/config-editor/index.html), load config-schema.json,
#    and set any of the ~1,650 parameters across ~290 scripts — enum dropdowns, live trap checks
#    (port collisions, GPU-fraction sums, mesh-replica hosts), then export your config.local.psd1.
```

## Run it

```powershell
Invoke-AitherScript 0000            # run one automation-script by number (e.g. 0000 = bootstrap)
Invoke-AitherPlaybook bootstrap     # run an orchestration playbook
az 0402                             # shorthand: run script 0402 (unit tests)
seq test-quick                      # run a named sequence
```

## Drive it from an agent (aither-adk)

The `aitherzero` tool pack gives an [aither-adk](aither-adk.md) agent the same surface as tools —
so the agent can inventory scripts, generate + validate configs, plan deployments, and even author
new automation-scripts:

```bash
python -m adk.toolpacks.aitherzero inventory                 # list categories, scripts, playbooks
python -m adk.toolpacks.aitherzero describe Bootstrap-AitherOS
python -m adk.toolpacks.aitherzero validate --path config.psd1   # fail-closed trap checks
```

The pack's `az_*` tools (`az_inventory`, `az_describe_script`, `az_export_schema`,
`az_generate_config`, `az_validate_config`, `az_plan_playbook`, `az_scaffold_script`) let the agent
self-manage the whole inventory and generate deployments.

## Part of one substrate

AitherZero provisions the box; [AitherNode](aithernode.md) makes its hardware usable,
[AitherConnect](aitherconnect.md) wires it to the fleet, [aither-adk](aither-adk.md) is the runtime
that drives all of it, and [OmniNode](omninode-node.md) pools the results into one compute fabric.
One motion, not five.

MIT-licensed, like everything in `aither-skills`.
