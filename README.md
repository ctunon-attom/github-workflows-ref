# github-workflows-ref

Reference implementation for GitHub workflow governance on a Django project deployed to Render.

Built as a response to a [security and governance audit](docs/) of an existing production repo. Every control recommended in that audit is either implemented here or documented with the steps to enable it.

## Quick Start

```bash
# Clone and set up
git clone https://github.com/ctunon-attom/github-workflows-ref.git
cd github-workflows-ref
pipenv install --dev

# Install pre-commit hooks (one-time — mirrors CI lint + secret scan locally)
pipenv run pre-commit install
pipenv run pre-commit install --hook-type pre-push

# Run locally
pipenv run python manage.py migrate
pipenv run python manage.py runserver

# Run tests
pipenv run pytest --cov=taskapp --cov-fail-under=80

# Lint
pipenv run ruff check taskapp/ config/
pipenv run ruff format --check taskapp/ config/
```

## Branch Strategy

```
feature/* ──PR──> develop ──push──> staging ──PR──> master
                     │                 │               │
                     ▼                 ▼               ▼
                development        staging        production
                (Render)           (Render)        (Render)
```

| Branch | Environment | Deploy trigger |
|--------|-------------|----------------|
| `master` | `production` | Auto after CI passes |
| `staging` | `staging` | Auto after CI passes |
| `develop` | `development` | Auto after CI passes |

## Workflows

| File | Purpose | Audit fix |
|------|---------|-----------|
| [`ci.yml`](.github/workflows/ci.yml) | Test + lint on push/PR | Lint is **blocking** (no `continue-on-error`), coverage at 80% |
| [`deploy.yml`](.github/workflows/deploy.yml) | Deploy to Render after CI passes | Single workflow, environment resolved from branch. Every deploy has an `environment:` key (was missing on production in audited repo) |
| [`deploy-feature.yml`](.github/workflows/deploy-feature.yml) | Per-PR Render preview envs (create/redeploy on open/sync, teardown on close) | Previews were ad-hoc; now blueprint-driven and auto-torn-down |
| [`cleanup-orphaned-envs.yml`](.github/workflows/cleanup-orphaned-envs.yml) | Weekly sweep of feature envs without an open PR | Orphan envs accumulated indefinitely in the audited repo |
| [`codeql.yml`](.github/workflows/codeql.yml) | Static analysis (weekly + on push) | Was completely absent |

## Governance Controls

### Implemented in this repo

- **SHA-pinned actions** — all third-party actions pinned to commit SHAs, not mutable tags
- **Minimal permissions** — every workflow declares explicit `permissions:` (default: read)
- **CODEOWNERS** — workflows, Dockerfile, settings, and Pipfile require owner review
- **Dependabot** — weekly updates for pip and github-actions ecosystems
- **CodeQL** — automated static analysis for Python
- **SECURITY.md** — vulnerability reporting instructions
- **Single deploy workflow** — environment resolved from branch, no ambiguity
- **`autoDeploy: false`** — Render does not auto-deploy; GitHub Actions orchestrates deploys after CI

### Requires GitHub Pro or Organization

Documented in [`docs/`](docs/) with exact settings and API commands:

- **Branch protection** — required reviews, status checks, signed commits, force-push blocks → [BRANCH_PROTECTION.md](docs/BRANCH_PROTECTION.md)
- **Secret scoping** — environment-scoped secrets with deployment branch policies → [SECRET_SCOPING.md](docs/SECRET_SCOPING.md)
- **Repo settings** — squash-only merges, auto-delete branches, token permissions → [REPO_SETTINGS.md](docs/REPO_SETTINGS.md)

## Environment Setup on GitHub

1. **Create environments** in Settings → Environments: `production`, `staging`, `development`, `preview`
2. **Add secrets** to each environment per [SECRET_SCOPING.md](docs/SECRET_SCOPING.md)
3. **Set deployment branch policies** (requires Pro/Team):
   - `production` → `master`
   - `staging` → `staging`
   - `development` → `develop`
4. **Add required reviewers** on `production` and `preview`. `production` gates merges to master; `preview` gates every Render feature-env deploy, so reviewers see and approve each per-PR preview before it consumes a free-tier slot.
5. **Apply repo settings** per [REPO_SETTINGS.md](docs/REPO_SETTINGS.md)

## Stack

- Python 3.13, Django 5+, HTMX
- pipenv for dependency management
- SQLite everywhere — see note below
- Render for hosting
- GitHub Actions for CI/CD

### Why SQLite?

This repo exists to exercise GitHub CI/CD pipelines, not to run a real app.
SQLite keeps every environment self-contained: no database service to
provision, no 90-day Render Postgres clock to track, no `DATABASE_URL` to
thread through feature envs. Migrations rebuild the schema on every boot,
`/health/` answers 200, the deploy workflow verifies end-to-end. Data does
not persist across redeploys — that's fine here.

If you fork this as a template for a real app, swap back to Postgres by
restoring a `databases:` block in `render.yaml` and adding `DATABASE_URL`
to the service envVars — `config/settings.py` already picks it up via
`dj-database-url` when set.
