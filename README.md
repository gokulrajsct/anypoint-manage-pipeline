# anypoint-manage-pipeline

Declarative deployment of **Anypoint API Manager** API instances and their **policies**
from Azure DevOps, driven by the **Anypoint CLI v4** and a **PowerShell** module. Desired
state is one YAML file per API per environment, kept in a **separate config repo**.

> Runtime Manager / Mule app deployment is **out of scope** — a separate pipeline owns
> that. This one only touches API Manager: instance definition, promotion, policies.

---

## What it does

**One pipeline, no per-API code.** Every `*.yaml` under `config/<env>/` in the config
repo is an API ("project"). The pipeline enumerates them (`-Api all`) and reconciles each.
Onboard a new API by adding its config files — no pipeline change.

`action: deploy` promotes through environment **stages**: `Test → UAT → PreProd → Prod`.
`PreProd` and `Prod` are gated by **approvals** (ADO Environment checks). The
`targetEnvironment` parameter chooses how far a run goes.

Per environment + API:

| Situation | Action |
|---|---|
| Instance exists, config == live | **nothing** |
| Instance exists, config != live | apply only the differing policies (add / edit / remove / enable-disable) |
| Instance missing, initial env (`test`) | `anypoint-cli-v4 api-mgr api manage …` (create from scratch), then apply all policies |
| Instance missing, higher env (`uat`/`preprod`/`prod`) | `anypoint-cli-v4 api-mgr api promote …` from the previous env, then reconcile policies on top |
| `action: extract` (initial env only) | read live `test` policies → write them into `config/test/<api>.yaml` → commit to the config repo's default branch |

Policy reconcile is **declarative**: the config file is the source of truth. A policy
applied on the API but absent from the file is **pruned** (per-API `prune: true`, default).
Set `prune: false` to have it reported as drift instead of deleted.

**CLI limitation:** `api-mgr policy apply/edit` have no `--order` flag, so policy
**ordering cannot be changed** by this tool. Order mismatches are surfaced as warnings;
fix them in the API Manager UI or via the REST API.

---

## Config repo layout

```
anypoint-policy-config/                # separate git repo
  config/
    test/     orders-api.yaml  payments-api.yaml  ...
    uat/      orders-api.yaml  payments-api.yaml  ...
    preprod/  orders-api.yaml  ...
    prod/     orders-api.yaml  ...
```

One file = one API instance in one environment. **The file name (stem) is the API key.**
The pipeline discovers the API list by globbing `config/<env>/*.yaml` — that is the only
inventory of "projects". Editor schema:
[`schema/api-config.schema.json`](schema/api-config.schema.json). Annotated example:
[`config/test/orders-api.yaml`](config/test/orders-api.yaml).

```yaml
apiInstance:
  assetId: orders-api             # Exchange asset id of the API spec
  groupId: null                   # null -> current org (ANYPOINT_ORG)
  assetVersion: "1.0.3"
  instanceLabel: orders-api-uat   # unique per env; the lookup key
  deploymentType: cloudhub2       # cloudhub | cloudhub2 | hybrid | rtf
  endpoint:
    implementationUri: https://orders-backend.uat/   # --uri
    type: http                                       # --type
    scheme: https
    port: 8081
    path: /
    withProxy: true
    muleVersion4OrAbove: true
promotion:
  fromEnvironment: test          # source env for a promote; null in the initial env
  sourceInstanceLabel: orders-api-test
  copyTiers: true
  copyPolicies: false            # keep false: policies are managed by this file
prune: true
policies:
  - assetId: rate-limiting-sla
    groupId: 68ef9520-24e9-4cf2-b2f5-620025690913    # MuleSoft org (standard policies)
    version: "1.4.0"
    order: 1
    configurationData:
      rateLimits: [{ maximumRequests: 200, timePeriodInMilliseconds: 60000 }]
```

**Config files** may be YAML (`.yaml` / `.yml`) or JSON (`.json`) — one file per API per
environment, the file stem is the API key. Don't define the same stem twice in a dir.

**Live policy read:** the engine reads applied policies from the **Anypoint Platform REST
API** (`GET …/apimanager/api/v1/organizations/{org}/environments/{env}/apis/{id}/policies`),
using a `client_credentials` token from the same `ANYPOINT_CLIENT_ID` / `ANYPOINT_CLIENT_SECRET`.
This returns a structured `configurationData` object. If the REST call fails it falls back to
`anypoint-cli-v4 api-mgr policy list` (whose `--output json` is a stringified table that the
engine parses best-effort). Set `APIM_POLICY_READ=cli` to force the CLI path.

**Masked secrets:** sensitive `configurationData` values come back masked (`********`). The
engine ignores masked fields when diffing (so they never look like drift) and, on `extract`,
keeps the value already present in the config file. A real change to a secret must be made in
the config file.

---

## Azure DevOps setup

1. **Pipeline**: point a pipeline at [`azure-pipelines.yml`](azure-pipelines.yml). Set
   `resources.repositories.configRepo.name` to your config repo. Azure DevOps clones both
   repos via the `checkout` steps (this repo → `.../pipeline`, the config repo →
   `.../config-repo`); the scripts never run `git clone`. A merge to the config repo's
   `main` triggers the pipeline (`resources.repositories.configRepo.trigger`).
2. **One variable group per environment** — `anypoint-test`, `anypoint-uat`,
   `anypoint-preprod`, `anypoint-prod` (ideally linked to Azure Key Vault):

   | Variable | Secret? | Value |
   |---|---|---|
   | `ANYPOINT_CLIENT_ID` | **yes** | Connected App client id for that env's business group |
   | `ANYPOINT_CLIENT_SECRET` | **yes** | Connected App client secret |
   | `ANYPOINT_ORG` | no | business group / org name or id |
   | `APIM_ENV_MAP` | no | JSON logical→Anypoint env name, e.g. `{"test":"Test","uat":"UAT","preprod":"Pre-Prod","prod":"Production"}` |
   | `ANYPOINT_HOST` | no (optional) | `eu1.anypoint.mulesoft.com` for the EU control plane |

3. **ADO Environments** `anypoint-test` / `anypoint-uat` / `anypoint-preprod` /
   `anypoint-prod` (auto-created on first run). On **`anypoint-preprod`** and
   **`anypoint-prod`** add an **Approvals** check (*Environments → … → Approvals and
   checks*). That is what gates those stages — nothing in YAML.
4. **Connected App** (client-credentials grant), per business group / env — scopes:
   *API Manager: View APIs Configuration, Manage APIs Configuration, Manage Policies*;
   for promotion the same scopes on the **source** environment too.
5. **Config-repo push** (for `action: extract`): grant the build service **Contribute** on
   the config repo; the extract job checks out with `persistCredentials: true`.

Each job installs `anypoint-cli-v4` + the `api-mgr` plugin and the `powershell-yaml`
module, then runs `Invoke-ApimSync.ps1`.

### Pipeline parameters (set when queued manually)

| Parameter | Default | Meaning |
|---|---|---|
| `action` | `deploy` | `deploy` = run the Test→UAT→PreProd→Prod stages; `extract` = pull live policies from the initial env and commit them |
| `targetEnvironment` | `test` | how far a `deploy` run promotes (`test` / `uat` / `preprod` / `prod`) — later stages are skipped by `condition` |
| `apiKey` | `all` | one config stem (`orders-api`) or `all` APIs in the config repo |
| `dryRun` | `true` | `true` = plan only, no changes. For `extract`, `true` = write + commit locally but do **not** push |
| `createMode` | `auto` | `auto` (scratch in the initial env, promote elsewhere) / `scratch` / `promote` |
| `prune` | `fromconfig` | override the per-API `prune` flag |

`APIM_INITIAL_ENV` is set to `test` by the pipeline (`variables.initialEnv`); change it in
one place if your first environment is named differently. Each stage publishes
`plan-<env>.json` as a build artifact.

---

## Local development & testing

```powershell
npm install -g anypoint-cli-v4
anypoint-cli-v4 plugins:install anypoint-cli-api-mgr-plugin
Install-Module powershell-yaml -Scope CurrentUser -Force
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

Invoke-Pester ./tests          # 23 tests, no network (Anypoint CLI mocked)
```

Offline config check:

```powershell
./Invoke-ApimSync.ps1 -Action validate -ConfigDir ./config/test
```

Against a real sandbox — copy `local/.env.example` to `local/.env`, fill it, then:

```powershell
./local/run-local.ps1 -Action login-check                  # verify creds, list envs
./local/run-local.ps1 -Env test -Api orders-api            # dry-run reconcile (prints plan)
./local/run-local.ps1 -Env test -Api orders-api -Apply     # apply
./local/run-local.ps1 -Env uat  -Api orders-api            # dry-run the promote path
./local/run-local.ps1 -Env test -Api orders-api -Action extract   # live -> config file
```

---

## Code map

| File | Responsibility |
|---|---|
| `Invoke-ApimSync.ps1` | entry point: `reconcile` / `extract` / `validate` / `login-check` |
| `src/ApimSync/ApimSync.psm1` | the module — everything below |
| &nbsp;&nbsp;`Read-ApimConfig`, `Get-ApimConfigList` | load + validate config (YAML or JSON) |
| &nbsp;&nbsp;`ConvertTo-ApimNormalizedPolicy` | normalise desired / live policy to a comparable shape |
| &nbsp;&nbsp;`ConvertFrom-ApimConfigBlob` | parse the CLI's stringified `Configuration` table cell (fallback path) |
| &nbsp;&nbsp;`Test-ApimConfigTreeEqual` / `Get-ApimConfigTreeDiff` | deep config compare + per-field diff log, mask-aware |
| &nbsp;&nbsp;`Get-ApimPolicyPlan` | desired vs live → Add / Edit / Remove / Toggle / Drift plan |
| &nbsp;&nbsp;`Invoke-AnypointCli` | run `anypoint-cli-v4`, capture JSON, surface errors |
| &nbsp;&nbsp;`Get-ApimAccessToken` / `Invoke-ApimRest` / `Get-ApimAppliedPolicyViaRest` | REST read path (token + policies GET) |
| &nbsp;&nbsp;`Get-ApimInstanceId` / `New-ApimInstance` / `Invoke-ApimPromotion` / `Get-ApimAppliedPolicy` / `Add`/`Set`/`Remove-ApimPolicy` | CLI wrappers (`Get-ApimAppliedPolicy` = REST with CLI fallback) |
| &nbsp;&nbsp;`Invoke-ApimReconcile` | orchestration: exists? → create/promote → apply plan → verify |
| &nbsp;&nbsp;`Export-ApimConfig` | live policies → config-file `policies:` list (dev only) |
| &nbsp;&nbsp;`Invoke-ApimConfigCommit` | stage / commit / push updated config files |

### Exit codes

`0` ok / no changes · `3` drift found (reconcile, `prune:false`) · `4` runtime/auth/config error.
