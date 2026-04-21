# Secret Scoping by Environment

## The problem

When all secrets live at repo level, **any workflow on any branch** can access production credentials. A compromised feature branch or a `workflow_dispatch` trigger can reach `RENDER_PROD_API_KEY`.

## The fix

Move secrets into their target **GitHub Environment**. Each environment can restrict which branches may access it via a **deployment branch policy**.

## Secret assignment

### `production` environment

Deployment branch policy: **`master` only**

| Secret | Purpose |
|--------|---------|
| `RENDER_API_KEY` | Render API authentication |
| `RENDER_SERVICE_ID_WEB` | Render service ID for production web |
| `RENDER_BLUEPRINT_SYNC_HOOK` | Blueprint sync webhook URL |
| `RENDER_HEALTH_URL` | Production URL for health check |

### `staging` environment

Deployment branch policy: **`staging` only**

| Secret | Purpose |
|--------|---------|
| `RENDER_API_KEY` | Render API authentication |
| `RENDER_SERVICE_ID_WEB` | Render service ID for staging web |
| `RENDER_BLUEPRINT_SYNC_HOOK` | Blueprint sync webhook URL |
| `RENDER_HEALTH_URL` | Staging URL for health check |

### `development` environment

Deployment branch policy: **`develop` only**

| Secret | Purpose |
|--------|---------|
| `RENDER_API_KEY` | Render API authentication |
| `RENDER_SERVICE_ID_WEB` | Render service ID for dev web |
| `RENDER_BLUEPRINT_SYNC_HOOK` | Blueprint sync webhook URL |
| `RENDER_HEALTH_URL` | Development URL for health check |

### Repo-level secrets

**None.** Every secret is scoped to an environment.

Only use repo-level secrets for truly environment-agnostic values (e.g. a Codecov upload token or a notification webhook shared across all environments).

## How it works

When a workflow job declares `environment: production`, GitHub:

1. Checks the **deployment branch policy** — if the workflow is running on a branch not in the policy, the job is **skipped**.
2. Checks **required reviewers** — if configured, the job pauses until approved.
3. Injects **environment-scoped secrets** into the job. Repo-level secrets are also available but environment secrets take precedence on name collision.

This means a `workflow_dispatch` from `develop` cannot access `production` secrets even if someone manually selects it — the branch policy blocks it.

## Environment protection rules

| Environment | Required reviewers | Wait timer | Admin bypass |
|-------------|-------------------|------------|-------------|
| `production` | 1 reviewer | None | **Disabled** |
| `staging` | None | None | Enabled |
| `development` | None | None | Enabled |

## Plan requirements

Environment protection rules (required reviewers, deployment branch policies) require:
- **GitHub Pro** on personal accounts, or
- **GitHub Team** on organization accounts

On Free plans, environments exist but protection rules are ignored.
