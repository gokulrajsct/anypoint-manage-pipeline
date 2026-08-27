# Local runners

`run-local.ps1` wraps `../Invoke-ApimSync.ps1`, loading `local/.env` first.

## Prerequisites

```powershell
npm install -g anypoint-cli-v4
anypoint-cli-v4 plugins:install anypoint-cli-api-mgr-plugin
Install-Module powershell-yaml -Scope CurrentUser -Force     # runtime dependency
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck   # tests only
```

Then `cp .env.example .env` and fill in the connected-app id/secret, `ANYPOINT_ORG`
and `APIM_ENV_MAP`.

## Usage

| Task | Command |
|---|---|
| Verify creds / list envs | `./run-local.ps1 -Action login-check` |
| Validate config (offline) | `./run-local.ps1 -Action validate -Env test` |
| Dry-run reconcile | `./run-local.ps1 -Env test -Api orders-api` |
| Apply reconcile | `./run-local.ps1 -Env test -Api orders-api -Apply` |
| Extract live -> config | `./run-local.ps1 -Env test -Api orders-api -Action extract` |
| Extract + commit + push | `./run-local.ps1 -Env test -Api orders-api -Action extract -Commit -Push` |

Dry-run reconcile only calls read commands (`api list`, `policy list`) and prints the
plan to stdout and `../plan.json`. `.env` and `plan.json` are git-ignored.

## Tests

```powershell
Invoke-Pester ./tests
```

23 tests, no network — the Anypoint CLI is mocked with Pester `Mock`.
