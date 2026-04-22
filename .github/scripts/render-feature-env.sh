#!/usr/bin/env bash
# =============================================================================
# Render Feature Environment Helpers (simplified for single-service apps)
#
# Creates an isolated web service + PostgreSQL per feature branch on Render.
# Adapted from the Forgen production feature-env system.
#
# Required env vars:
#   RENDER_API_KEY              — Render API bearer token
#   RENDER_OWNER_ID             — Render workspace/owner ID
#   RENDER_REPO_URL             — Git repo URL (https, not ssh)
#
# Optional env vars:
#   RENDER_PROJECT_ID           — Render project ID (groups services)
#   RENDER_FEATURE_ENV_GROUP_ID — Env group ID (shared secrets)
#   RENDER_REGION               — Region (default: oregon)
#   FEATURE_ENV_MAX             — Max concurrent feature environments (default: 3)
# =============================================================================
set -euo pipefail

RENDER_API="https://api.render.com/v1"
RENDER_REGION="${RENDER_REGION:-oregon}"
PG_VERSION="16"
DB_POLL_TIMEOUT=300
DB_POLL_INTERVAL=10
DEPLOY_POLL_TIMEOUT=600
DEPLOY_POLL_INTERVAL=15

# -----------------------------------------------------------------------------
# Sanitize a git branch name into a Render-safe slug.
# Lowercase, strip common prefixes, replace non-alnum with hyphens, truncate.
# -----------------------------------------------------------------------------
sanitize_branch_name() {
  local branch="$1"
  echo "$branch" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#^(feat|feature|fix|hotfix|bugfix|chore|release|refactor)[/\-]##' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//' \
    | cut -c1-28
}

# -----------------------------------------------------------------------------
# API helper: wraps curl with auth and error handling.
# Usage: render_api GET /services
#        render_api POST /postgres '{"name":"foo",...}'
# -----------------------------------------------------------------------------
render_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local args=(
    --fail-with-body --silent --show-error
    -X "$method"
    -H "Authorization: Bearer ${RENDER_API_KEY:?RENDER_API_KEY is not set}"
    -H "Accept: application/json"
    -H "Content-Type: application/json"
  )
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}" "$RENDER_API$path"
}

# -----------------------------------------------------------------------------
# Find a service by exact name. Returns service ID or empty string.
# -----------------------------------------------------------------------------
find_service_by_name() {
  local name="$1"
  render_api GET "/services?name=${name}&ownerId=${RENDER_OWNER_ID}&limit=1" \
    | jq -r '.[0].service.id // empty'
}

# -----------------------------------------------------------------------------
# Find a postgres instance by exact name. Returns postgres ID or empty string.
# -----------------------------------------------------------------------------
find_postgres_by_name() {
  local name="$1"
  render_api GET "/postgres?name=${name}&ownerId=${RENDER_OWNER_ID}&limit=1" \
    | jq -r '.[0].postgres.id // empty'
}

# -----------------------------------------------------------------------------
# Count active feature environment web services.
# -----------------------------------------------------------------------------
count_feature_envs() {
  local count=0
  local cursor=""
  while true; do
    local url="/services?type=web_service&ownerId=${RENDER_OWNER_ID}&limit=100"
    [ -n "$cursor" ] && url="${url}&cursor=${cursor}"
    local response
    response=$(render_api GET "$url")

    local page_count
    page_count=$(echo "$response" | jq '[.[] | select(.service.name | startswith("ref-feat-"))] | length')
    count=$((count + page_count))

    local next_cursor
    next_cursor=$(echo "$response" | jq -r '.[-1].cursor // empty')
    if [ -z "$next_cursor" ] || [ "$(echo "$response" | jq length)" -lt 100 ]; then
      break
    fi
    cursor="$next_cursor"
  done
  echo "$count"
}

# -----------------------------------------------------------------------------
# List all active feature environments.
# Outputs: JSON array of { name, id, createdAt }
# -----------------------------------------------------------------------------
list_feature_envs() {
  local result="[]"
  local cursor=""
  while true; do
    local url="/services?type=web_service&ownerId=${RENDER_OWNER_ID}&limit=100"
    [ -n "$cursor" ] && url="${url}&cursor=${cursor}"
    local response
    response=$(render_api GET "$url")

    local page_envs
    page_envs=$(echo "$response" | jq '[.[] | select(.service.name | startswith("ref-feat-")) | { name: .service.name, id: .service.id, createdAt: .service.createdAt }]')
    result=$(echo "$result" "$page_envs" | jq -s 'add')

    local next_cursor
    next_cursor=$(echo "$response" | jq -r '.[-1].cursor // empty')
    if [ -z "$next_cursor" ] || [ "$(echo "$response" | jq length)" -lt 100 ]; then
      break
    fi
    cursor="$next_cursor"
  done
  echo "$result"
}

# -----------------------------------------------------------------------------
# Wait for PostgreSQL to become available.
# -----------------------------------------------------------------------------
wait_for_postgres() {
  local pg_id="$1"
  local elapsed=0

  while [ "$elapsed" -lt "$DB_POLL_TIMEOUT" ]; do
    local status
    status=$(render_api GET "/postgres/$pg_id" | jq -r '.status // empty')
    echo "  [${elapsed}s] postgres status: ${status:-unknown}" >&2

    if [ "$status" = "available" ]; then
      echo "PostgreSQL $pg_id is available." >&2
      return 0
    fi
    if [ "$status" = "unavailable" ] || [ "$status" = "suspended" ]; then
      echo "ERROR: PostgreSQL $pg_id entered status: $status" >&2
      return 1
    fi

    sleep "$DB_POLL_INTERVAL"
    elapsed=$((elapsed + DB_POLL_INTERVAL))
  done

  echo "ERROR: PostgreSQL $pg_id timed out after ${DB_POLL_TIMEOUT}s." >&2
  return 1
}

# -----------------------------------------------------------------------------
# Get connection info for a postgres instance.
# -----------------------------------------------------------------------------
get_connection_info() {
  local pg_id="$1"
  render_api GET "/postgres/$pg_id/connection-info" \
    | jq '{ internal: .internalConnectionString, external: .externalConnectionString }'
}

# -----------------------------------------------------------------------------
# Cancel the auto-triggered deploy on a newly created service.
# -----------------------------------------------------------------------------
cancel_auto_deploy() {
  local service_id="$1"
  local deploy_id=""
  local elapsed=0

  while [ "$elapsed" -lt 30 ]; do
    deploy_id=$(render_api GET "/services/$service_id/deploys?limit=1" \
      | jq -r '.[0].deploy.id // .[0].id // empty')
    [ -n "$deploy_id" ] && break
    sleep 2
    elapsed=$((elapsed + 2))
  done

  if [ -z "$deploy_id" ]; then
    echo "  No auto-deploy found to cancel." >&2
    return 0
  fi

  echo "  Cancelling auto-deploy $deploy_id..." >&2
  render_api POST "/services/$service_id/deploys/$deploy_id/cancel" > /dev/null 2>&1 || {
    echo "  WARNING: Could not cancel deploy — may have already completed." >&2
  }
}

# -----------------------------------------------------------------------------
# Link a service to an environment group (shared secrets).
# -----------------------------------------------------------------------------
link_env_group() {
  local service_id="$1"
  local env_group_id="${RENDER_FEATURE_ENV_GROUP_ID:-}"

  if [ -z "$env_group_id" ]; then
    echo "  No env group configured — skipping." >&2
    return 0
  fi

  echo "  Linking service $service_id to env group $env_group_id" >&2
  render_api POST "/env-groups/${env_group_id}/services/${service_id}" > /dev/null
}

# -----------------------------------------------------------------------------
# Trigger a deploy on a service.
# Outputs: deploy ID
# -----------------------------------------------------------------------------
trigger_feature_deploy() {
  local service_id="$1"
  local response
  response=$(curl --silent --show-error \
    -X POST \
    -H "Authorization: Bearer ${RENDER_API_KEY}" \
    -H "Accept: application/json" \
    "$RENDER_API/services/$service_id/deploys")

  local deploy_id
  deploy_id=$(echo "$response" | jq -r '.id // .deploy.id // empty' 2>/dev/null)

  if [ -z "$deploy_id" ]; then
    sleep 2
    deploy_id=$(render_api GET "/services/$service_id/deploys?limit=1" \
      | jq -r '.[0].deploy.id // .[0].id // empty')
  fi

  if [ -z "$deploy_id" ]; then
    echo "ERROR: Failed to get deploy ID for service $service_id." >&2
    return 1
  fi

  echo "$deploy_id"
}

# -----------------------------------------------------------------------------
# Poll a deploy until terminal state.
# Returns 0 on "live", 1 on failure or timeout.
# -----------------------------------------------------------------------------
poll_feature_deploy() {
  local service_id="$1"
  local deploy_id="$2"
  local elapsed=0
  local failure_states="deactivated|build_failed|pre_deploy_failed|update_failed|canceled"

  echo "Polling deploy $deploy_id..." >&2
  while [ "$elapsed" -lt "$DEPLOY_POLL_TIMEOUT" ]; do
    local status
    status=$(render_api GET "/services/$service_id/deploys/$deploy_id" \
      | jq -r '.deploy.status // .status // empty')
    echo "  [${elapsed}s] status: ${status:-unknown}" >&2

    if [ "$status" = "live" ]; then
      echo "Deploy is LIVE." >&2
      return 0
    fi
    if echo "$status" | grep -qE "^($failure_states)$"; then
      echo "ERROR: Deploy failed with status: $status" >&2
      return 1
    fi

    sleep "$DEPLOY_POLL_INTERVAL"
    elapsed=$((elapsed + DEPLOY_POLL_INTERVAL))
  done

  echo "ERROR: Deploy timed out after ${DEPLOY_POLL_TIMEOUT}s." >&2
  return 1
}

# -----------------------------------------------------------------------------
# Create a PostgreSQL instance.
# Usage: create_postgres <slug> <plan>
# Outputs: postgres ID
# -----------------------------------------------------------------------------
create_postgres() {
  local slug="$1"
  local plan="${2:-free}"
  local name="ref-feat-${slug}-db"

  echo "Creating PostgreSQL: $name (plan: $plan)" >&2

  local body
  body=$(jq -n \
    --arg name "$name" \
    --arg plan "$plan" \
    --arg ownerId "$RENDER_OWNER_ID" \
    --arg version "$PG_VERSION" \
    --arg region "$RENDER_REGION" \
    --arg dbName "ref_feat_${slug//-/_}" \
    --arg dbUser "ref_feat_user" \
    '{
      name: $name,
      plan: $plan,
      ownerId: $ownerId,
      version: $version,
      region: $region,
      databaseName: $dbName,
      databaseUser: $dbUser
    }')

  local response
  response=$(render_api POST /postgres "$body")
  local pg_id
  pg_id=$(echo "$response" | jq -r '.id // empty')

  if [ -z "$pg_id" ]; then
    echo "ERROR: Failed to create postgres. Response: $response" >&2
    return 1
  fi

  echo "Created postgres $pg_id — waiting for availability..." >&2
  wait_for_postgres "$pg_id"
  echo "$pg_id"
}

# -----------------------------------------------------------------------------
# Create a feature web service.
# Usage: create_web_service <branch> <slug> <db_conn> <plan>
# Outputs: service ID
# -----------------------------------------------------------------------------
create_web_service() {
  local branch="$1"
  local slug="$2"
  local db_conn="$3"
  local plan="${4:-free}"
  local name="ref-feat-${slug}-web"

  echo "Creating web service: $name (plan: $plan)" >&2

  local env_vars
  env_vars=$(jq -n \
    --arg db "$db_conn" \
    '[
      { key: "DJANGO_SETTINGS_MODULE", value: "config.settings" },
      { key: "DEBUG", value: "False" },
      { key: "ALLOWED_HOSTS", value: ".onrender.com" },
      { key: "DATABASE_URL", value: $db },
      { key: "PYTHON_VERSION", value: "3.13.2" }
    ]')

  local build_cmd="pip install pipenv && pipenv install --deploy --ignore-pipfile"
  local start_cmd="python manage.py migrate && python manage.py collectstatic --noinput && gunicorn config.wsgi:application --bind 0.0.0.0:\$PORT --workers 2 --threads 2 --timeout 120"

  local body
  body=$(jq -n \
    --arg name "$name" \
    --arg ownerId "$RENDER_OWNER_ID" \
    --arg repo "$RENDER_REPO_URL" \
    --arg branch "$branch" \
    --arg plan "$plan" \
    --arg region "$RENDER_REGION" \
    --arg buildCmd "$build_cmd" \
    --arg startCmd "$start_cmd" \
    --argjson envVars "$env_vars" \
    '{
      type: "web_service",
      name: $name,
      ownerId: $ownerId,
      repo: $repo,
      branch: $branch,
      autoDeploy: "no",
      serviceDetails: {
        runtime: "python",
        plan: $plan,
        region: $region,
        numInstances: 1,
        envSpecificDetails: {
          buildCommand: $buildCmd,
          startCommand: $startCmd
        },
        healthCheckPath: "/health/"
      },
      envVars: $envVars
    }')

  local response
  response=$(render_api POST /services "$body")
  local service_id
  service_id=$(echo "$response" | jq -r '.service.id // .id // empty')

  if [ -z "$service_id" ]; then
    echo "ERROR: Failed to create web service. Response: $response" >&2
    return 1
  fi

  cancel_auto_deploy "$service_id"
  link_env_group "$service_id"
  echo "Created web service: $service_id" >&2
  echo "$service_id"
}

# -----------------------------------------------------------------------------
# Delete a service by ID. Tolerates 404.
# -----------------------------------------------------------------------------
delete_service() {
  local service_id="$1"
  echo "Deleting service: $service_id" >&2
  local http_status
  http_status=$(curl --silent --output /dev/null --write-out "%{http_code}" \
    -X DELETE \
    -H "Authorization: Bearer ${RENDER_API_KEY}" \
    "$RENDER_API/services/$service_id")
  echo "  HTTP $http_status" >&2
}

# -----------------------------------------------------------------------------
# Delete a postgres instance by ID. Tolerates 404.
# -----------------------------------------------------------------------------
delete_postgres() {
  local pg_id="$1"
  echo "Deleting postgres: $pg_id" >&2
  local http_status
  http_status=$(curl --silent --output /dev/null --write-out "%{http_code}" \
    -X DELETE \
    -H "Authorization: Bearer ${RENDER_API_KEY}" \
    "$RENDER_API/postgres/$pg_id")
  echo "  HTTP $http_status" >&2
}

# =============================================================================
# ORCHESTRATORS
# =============================================================================

# -----------------------------------------------------------------------------
# Create a full feature environment: postgres + web service + deploy.
# Usage: create_feature_env <branch> <slug> <web_plan> <db_plan>
# Outputs: JSON with service IDs and URL
# -----------------------------------------------------------------------------
create_feature_env() {
  local branch="$1"
  local slug="$2"
  local web_plan="${3:-free}"
  local db_plan="${4:-free}"
  local max_envs="${FEATURE_ENV_MAX:-3}"

  echo "========================================" >&2
  echo "Creating feature environment: ref-feat-${slug}" >&2
  echo "  Branch: $branch" >&2
  echo "  Plans:  web=$web_plan, db=$db_plan" >&2
  echo "========================================" >&2

  # Enforce cap
  local current_count
  current_count=$(count_feature_envs)
  if [ "$current_count" -ge "$max_envs" ]; then
    echo "ERROR: Feature env limit reached ($current_count/$max_envs)." >&2
    list_feature_envs | jq -r '.[].name' >&2
    return 1
  fi

  # Idempotency
  local existing_web_id
  existing_web_id=$(find_service_by_name "ref-feat-${slug}-web")
  if [ -n "$existing_web_id" ]; then
    echo "Feature env already exists (web: $existing_web_id) — skipping." >&2
    jq -n \
      --arg slug "$slug" \
      --arg web_id "$existing_web_id" \
      --arg web_url "https://ref-feat-${slug}-web.onrender.com" \
      '{ slug: $slug, web_service_id: $web_id, web_url: $web_url, already_existed: true }'
    return 0
  fi

  # 1. Create postgres
  local pg_id
  pg_id=$(create_postgres "$slug" "$db_plan")

  # 2. Get connection info
  local conn_info db_internal
  conn_info=$(get_connection_info "$pg_id")
  db_internal=$(echo "$conn_info" | jq -r '.internal')

  # 3. Create web service
  local web_id
  web_id=$(create_web_service "$branch" "$slug" "$db_internal" "$web_plan")

  # 4. Trigger deploy
  local deploy_id
  deploy_id=$(trigger_feature_deploy "$web_id")
  poll_feature_deploy "$web_id" "$deploy_id" || {
    echo "WARNING: Deploy did not reach live state." >&2
  }

  local web_url="https://ref-feat-${slug}-web.onrender.com"

  echo "========================================" >&2
  echo "Feature environment ready: $web_url" >&2
  echo "========================================" >&2

  jq -n \
    --arg slug "$slug" \
    --arg pg_id "$pg_id" \
    --arg web_id "$web_id" \
    --arg web_url "$web_url" \
    '{
      slug: $slug,
      postgres_id: $pg_id,
      web_service_id: $web_id,
      web_url: $web_url
    }'
}

# -----------------------------------------------------------------------------
# Destroy a feature environment (web service + postgres).
# Usage: destroy_feature_env <slug>
# -----------------------------------------------------------------------------
destroy_feature_env() {
  local slug="$1"
  local prefix="ref-feat-${slug}-"

  echo "Destroying feature environment: ref-feat-${slug}" >&2

  # Find and delete all services matching the prefix
  local cursor=""
  while true; do
    local url="/services?ownerId=${RENDER_OWNER_ID}&limit=100"
    [ -n "$cursor" ] && url="${url}&cursor=${cursor}"
    local response
    response=$(render_api GET "$url")

    local service_ids
    service_ids=$(echo "$response" | jq -r \
      --arg prefix "$prefix" \
      '.[] | select(.service.name | startswith($prefix)) | .service.id')

    for sid in $service_ids; do
      delete_service "$sid"
    done

    local next_cursor
    next_cursor=$(echo "$response" | jq -r '.[-1].cursor // empty')
    if [ -z "$next_cursor" ] || [ "$(echo "$response" | jq length)" -lt 100 ]; then
      break
    fi
    cursor="$next_cursor"
  done

  # Delete postgres
  local pg_id
  pg_id=$(find_postgres_by_name "ref-feat-${slug}-db")
  if [ -n "$pg_id" ]; then
    delete_postgres "$pg_id"
  fi

  echo "Feature environment ref-feat-${slug} destroyed." >&2
}
