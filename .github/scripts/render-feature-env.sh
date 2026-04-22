#!/usr/bin/env bash
# =============================================================================
# Render Feature Environment Helpers (blueprint-driven)
#
# Reads service definitions from .config/feature/render.yaml and creates
# Render resources via the API. The YAML template is the source of truth
# for what a feature environment looks like.
#
# Required env vars:
#   RENDER_API_KEY    — Render API bearer token
#   RENDER_OWNER_ID   — Render workspace/owner ID
#   RENDER_REPO_URL   — Git repo URL (https)
#
# Optional env vars:
#   RENDER_REGION     — Region (default: oregon)
#   FEATURE_ENV_MAX   — Max concurrent feature environments (default: 3)
# =============================================================================
set -euo pipefail

RENDER_API="https://api.render.com/v1"
RENDER_REGION="${RENDER_REGION:-oregon}"
DB_POLL_TIMEOUT=300
DB_POLL_INTERVAL=10
DEPLOY_POLL_TIMEOUT=600
DEPLOY_POLL_INTERVAL=15
BLUEPRINT_PATH="${BLUEPRINT_PATH:-.config/feature/render.yaml}"

# -----------------------------------------------------------------------------
# Sanitize a git branch name into a Render-safe slug.
# Accepts optional disambiguator (e.g. PR number) to prevent collisions
# when different branches share the same 28-char prefix.
# Usage: sanitize_branch_name <branch> [disambiguator]
# -----------------------------------------------------------------------------
sanitize_branch_name() {
  local branch="$1"
  local disambiguator="${2:-}"
  local slug
  slug=$(echo "$branch" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#^(feat|feature|fix|hotfix|bugfix|chore|release|refactor)[/\-]##' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//')

  if [ -n "$disambiguator" ]; then
    slug="${slug}-${disambiguator}"
  fi

  echo "$slug" | cut -c1-28
}

# -----------------------------------------------------------------------------
# Render API helper.
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
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" "$RENDER_API$path"
}

# =============================================================================
# BLUEPRINT PARSING
# Reads .config/feature/render.yaml and substitutes placeholders.
# Requires: yq (https://github.com/mikefarah/yq)
# =============================================================================

# -----------------------------------------------------------------------------
# Render the blueprint template with variable substitution.
# Usage: render_blueprint <slug> <branch> <database_url>
# Outputs: the rendered YAML to stdout
# -----------------------------------------------------------------------------
render_blueprint() {
  local slug="$1"
  local branch="$2"
  local database_url="${3:-}"
  local slug_underscore="${slug//-/_}"

  if [ ! -f "$BLUEPRINT_PATH" ]; then
    echo "ERROR: Blueprint template not found at $BLUEPRINT_PATH" >&2
    return 1
  fi

  sed \
    -e "s|{{SLUG}}|${slug}|g" \
    -e "s|{{SLUG_UNDERSCORE}}|${slug_underscore}|g" \
    -e "s|{{BRANCH}}|${branch}|g" \
    -e "s|{{DATABASE_URL}}|${database_url}|g" \
    "$BLUEPRINT_PATH"
}

# -----------------------------------------------------------------------------
# Parse a database definition from the rendered blueprint and build the
# Render API request body.
# Usage: parse_db_spec <rendered_yaml> <index>
# Outputs: JSON body for POST /postgres
# -----------------------------------------------------------------------------
parse_db_spec() {
  local yaml="$1"
  local idx="${2:-0}"

  echo "$yaml" | yq -o=json ".databases[$idx]" | jq \
    --arg ownerId "$RENDER_OWNER_ID" \
    --arg region "$RENDER_REGION" \
    '{
      name: .name,
      plan: .plan,
      ownerId: $ownerId,
      version: .version,
      region: $region,
      databaseName: .databaseName,
      databaseUser: .databaseUser
    }'
}

# -----------------------------------------------------------------------------
# Parse a service definition from the rendered blueprint and build the
# Render API request body.
# Usage: parse_service_spec <rendered_yaml> <index>
# Outputs: JSON body for POST /services
# -----------------------------------------------------------------------------
parse_service_spec() {
  local yaml="$1"
  local idx="${2:-0}"

  local svc_json
  svc_json=$(echo "$yaml" | yq -o=json ".services[$idx]")

  local svc_type svc_runtime
  svc_type=$(echo "$svc_json" | jq -r '.type')
  svc_runtime=$(echo "$svc_json" | jq -r '.runtime // "python"')

  echo "$svc_json" | jq \
    --arg ownerId "$RENDER_OWNER_ID" \
    --arg repo "$RENDER_REPO_URL" \
    --arg region "$RENDER_REGION" \
    --arg svcType "$svc_type" \
    --arg runtime "$svc_runtime" \
    '{
      type: $svcType,
      name: .name,
      ownerId: $ownerId,
      repo: $repo,
      branch: .branch,
      autoDeploy: (.autoDeploy // "no"),
      serviceDetails: {
        runtime: $runtime,
        plan: .plan,
        region: $region,
        numInstances: (.numInstances // 1),
        envSpecificDetails: (
          if $runtime == "docker" then
            { dockerfilePath: .dockerfilePath, dockerContext: "." }
          else
            { buildCommand: .buildCommand, startCommand: .startCommand }
          end
        )
      }
      + if .healthCheckPath then { healthCheckPath: .healthCheckPath } else {} end,
      envVars: .envVars
    }'
}

# =============================================================================
# RENDER RESOURCE HELPERS
# =============================================================================

find_service_by_name() {
  local name="$1"
  render_api GET "/services?name=${name}&ownerId=${RENDER_OWNER_ID}&limit=1" \
    | jq -r '.[0].service.id // empty'
}

find_postgres_by_name() {
  local name="$1"
  render_api GET "/postgres?name=${name}&ownerId=${RENDER_OWNER_ID}&limit=1" \
    | jq -r '.[0].postgres.id // empty'
}

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

wait_for_postgres() {
  local pg_id="$1"
  local elapsed=0
  while [ "$elapsed" -lt "$DB_POLL_TIMEOUT" ]; do
    local status
    status=$(render_api GET "/postgres/$pg_id" | jq -r '.status // empty')
    echo "  [${elapsed}s] postgres: ${status:-unknown}" >&2
    if [ "$status" = "available" ]; then
      return 0
    fi
    if [ "$status" = "unavailable" ] || [ "$status" = "suspended" ]; then
      echo "ERROR: PostgreSQL entered status: $status" >&2
      return 1
    fi
    sleep "$DB_POLL_INTERVAL"
    elapsed=$((elapsed + DB_POLL_INTERVAL))
  done
  echo "ERROR: PostgreSQL timed out after ${DB_POLL_TIMEOUT}s." >&2
  return 1
}

get_connection_info() {
  local pg_id="$1"
  render_api GET "/postgres/$pg_id/connection-info" \
    | jq '{ internal: .internalConnectionString, external: .externalConnectionString }'
}

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
  [ -z "$deploy_id" ] && return 0
  echo "  Cancelling auto-deploy $deploy_id..." >&2
  render_api POST "/services/$service_id/deploys/$deploy_id/cancel" > /dev/null 2>&1 || true
}

trigger_feature_deploy() {
  local service_id="$1"
  local response
  response=$(render_api POST "/services/$service_id/deploys")

  local deploy_id
  deploy_id=$(echo "$response" | jq -r '.id // .deploy.id // empty' 2>/dev/null)
  if [ -z "$deploy_id" ]; then
    sleep 2
    deploy_id=$(render_api GET "/services/$service_id/deploys?limit=1" \
      | jq -r '.[0].deploy.id // .[0].id // empty')
  fi
  if [ -z "$deploy_id" ]; then
    echo "ERROR: Failed to get deploy ID for $service_id." >&2
    return 1
  fi
  echo "$deploy_id"
}

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
      echo "ERROR: Deploy failed: $status" >&2
      return 1
    fi
    sleep "$DEPLOY_POLL_INTERVAL"
    elapsed=$((elapsed + DEPLOY_POLL_INTERVAL))
  done
  echo "ERROR: Deploy timed out after ${DEPLOY_POLL_TIMEOUT}s." >&2
  return 1
}

delete_service() {
  local service_id="$1"
  echo "Deleting service: $service_id" >&2
  render_api DELETE "/services/$service_id" > /dev/null
}

delete_postgres() {
  local pg_id="$1"
  echo "Deleting postgres: $pg_id" >&2
  render_api DELETE "/postgres/$pg_id" > /dev/null
}

# =============================================================================
# ORCHESTRATORS (blueprint-driven)
# =============================================================================

# -----------------------------------------------------------------------------
# Create a full feature environment from the blueprint template.
# Usage: create_feature_env <branch> <slug>
# Outputs: JSON with service IDs and URL
# -----------------------------------------------------------------------------
create_feature_env() {
  local branch="$1"
  local slug="$2"
  local max_envs="${FEATURE_ENV_MAX:-3}"

  echo "========================================" >&2
  echo "Creating feature env from blueprint: ref-feat-${slug}" >&2
  echo "  Branch:    $branch" >&2
  echo "  Blueprint: $BLUEPRINT_PATH" >&2
  echo "========================================" >&2

  # Enforce cap
  local current_count
  current_count=$(count_feature_envs)
  if [ "$current_count" -ge "$max_envs" ]; then
    echo "ERROR: Feature env limit reached ($current_count/$max_envs)." >&2
    list_feature_envs | jq -r '.[].name' >&2
    return 1
  fi

  # Idempotency — check first service name from blueprint
  local first_svc_name
  first_svc_name=$(render_blueprint "$slug" "$branch" "" | yq '.services[0].name')
  local existing_id
  existing_id=$(find_service_by_name "$first_svc_name")
  if [ -n "$existing_id" ]; then
    echo "Feature env already exists ($first_svc_name: $existing_id) — skipping." >&2
    jq -n \
      --arg slug "$slug" \
      --arg web_id "$existing_id" \
      --arg web_url "https://${first_svc_name}.onrender.com" \
      '{ slug: $slug, web_service_id: $web_id, web_url: $web_url, already_existed: true }'
    return 0
  fi

  # --- 1. Create databases from blueprint ---
  local rendered
  rendered=$(render_blueprint "$slug" "$branch" "PLACEHOLDER")

  local db_count
  db_count=$(echo "$rendered" | yq '.databases | length')

  local pg_ids=()
  local db_internal=""
  for (( i=0; i<db_count; i++ )); do
    local db_body db_name
    db_body=$(parse_db_spec "$rendered" "$i")
    db_name=$(echo "$db_body" | jq -r '.name')

    echo "Creating database: $db_name" >&2
    local response pg_id
    response=$(render_api POST /postgres "$db_body")
    pg_id=$(echo "$response" | jq -r '.id // empty')

    if [ -z "$pg_id" ]; then
      echo "ERROR: Failed to create database. Response: $response" >&2
      return 1
    fi

    echo "  Created: $pg_id — waiting for availability..." >&2
    wait_for_postgres "$pg_id"
    pg_ids+=("$pg_id")

    # Use first database's internal URL for DATABASE_URL substitution
    if [ "$i" -eq 0 ]; then
      local conn_info
      conn_info=$(get_connection_info "$pg_id")
      db_internal=$(echo "$conn_info" | jq -r '.internal')
    fi
  done

  # --- 2. Re-render blueprint with actual DATABASE_URL ---
  rendered=$(render_blueprint "$slug" "$branch" "$db_internal")

  # --- 3. Create services from blueprint ---
  local svc_count
  svc_count=$(echo "$rendered" | yq '.services | length')

  local service_ids=()
  local web_id="" web_url=""
  for (( i=0; i<svc_count; i++ )); do
    local svc_body svc_name svc_type
    svc_body=$(parse_service_spec "$rendered" "$i")
    svc_name=$(echo "$svc_body" | jq -r '.name')
    svc_type=$(echo "$svc_body" | jq -r '.type')

    echo "Creating service: $svc_name ($svc_type)" >&2
    local response service_id
    response=$(render_api POST /services "$svc_body")
    service_id=$(echo "$response" | jq -r '.service.id // .id // empty')

    if [ -z "$service_id" ]; then
      echo "ERROR: Failed to create service. Response: $response" >&2
      return 1
    fi

    cancel_auto_deploy "$service_id"
    service_ids+=("$service_id")

    # Track the first web service for URL and deploy
    if [ "$svc_type" = "web_service" ] && [ -z "$web_id" ]; then
      web_id="$service_id"
      web_url="https://${svc_name}.onrender.com"
    fi

    echo "  Created: $service_id" >&2
  done

  # --- 4. Trigger deploys on all services ---
  echo "Triggering deploys..." >&2
  local web_deploy_id=""
  for sid in "${service_ids[@]}"; do
    local deploy_id
    deploy_id=$(trigger_feature_deploy "$sid") || {
      echo "WARNING: Failed to trigger deploy for $sid" >&2
      continue
    }
    echo "  Deploy triggered for $sid: $deploy_id" >&2
    if [ "$sid" = "$web_id" ]; then
      web_deploy_id="$deploy_id"
    fi
  done

  # --- 5. Poll web deploy ---
  if [ -n "$web_deploy_id" ]; then
    poll_feature_deploy "$web_id" "$web_deploy_id" || {
      echo "WARNING: Web deploy did not reach live state." >&2
    }
  fi

  echo "========================================" >&2
  echo "Feature environment ready: $web_url" >&2
  echo "========================================" >&2

  jq -n \
    --arg slug "$slug" \
    --arg web_id "$web_id" \
    --arg web_url "$web_url" \
    --arg pg_ids "$(IFS=,; echo "${pg_ids[*]}")" \
    '{
      slug: $slug,
      web_service_id: $web_id,
      web_url: $web_url,
      postgres_ids: ($pg_ids | split(","))
    }'
}

# -----------------------------------------------------------------------------
# Destroy a feature environment. Finds all services/databases by name prefix.
# Usage: destroy_feature_env <slug>
# -----------------------------------------------------------------------------
destroy_feature_env() {
  local slug="$1"
  local prefix="ref-feat-${slug}-"

  echo "Destroying feature environment: ref-feat-${slug}" >&2

  # Delete all services matching prefix
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

  # Delete postgres by name
  local pg_id
  pg_id=$(find_postgres_by_name "ref-feat-${slug}-db")
  if [ -n "$pg_id" ]; then
    delete_postgres "$pg_id"
  fi

  echo "Feature environment ref-feat-${slug} destroyed." >&2
}
