#!/usr/bin/env bash
set -euo pipefail

RENDER_API="https://api.render.com/v1"
POLL_TIMEOUT=600
POLL_INTERVAL=15
SYNC_WAIT_TIMEOUT=60
FAILURE_STATES="deactivated|build_failed|pre_deploy_failed|canceled"

get_latest_deploy_id() {
    local service_id="$1"
    curl -sf "${RENDER_API}/services/${service_id}/deploys?limit=1" \
        -H "Authorization: Bearer ${RENDER_API_KEY}" \
        | jq -r '.[0].deploy.id'
}

trigger_deploy() {
    local service_id="$1"
    local response
    response=$(curl -sf -X POST "${RENDER_API}/services/${service_id}/deploys" \
        -H "Authorization: Bearer ${RENDER_API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"clearCache": "do_not_clear"}')
    echo "$response" | jq -r '.deploy.id'
}

wait_for_new_deploy_or_trigger() {
    local service_id="$1"
    local old_deploy_id="$2"
    local elapsed=0

    echo "Waiting for new deploy (current: ${old_deploy_id})..."
    while [ $elapsed -lt $SYNC_WAIT_TIMEOUT ]; do
        local current_id
        current_id=$(get_latest_deploy_id "$service_id")
        if [ "$current_id" != "$old_deploy_id" ]; then
            echo "$current_id"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "Blueprint sync did not trigger a new deploy within ${SYNC_WAIT_TIMEOUT}s, triggering manually..."
    trigger_deploy "$service_id"
}

poll_deploy() {
    local service_id="$1"
    local deploy_id="$2"
    local elapsed=0

    echo "Polling deploy ${deploy_id}..."
    while [ $elapsed -lt $POLL_TIMEOUT ]; do
        local status
        status=$(curl -sf "${RENDER_API}/services/${service_id}/deploys/${deploy_id}" \
            -H "Authorization: Bearer ${RENDER_API_KEY}" \
            | jq -r '.status')

        echo "  [${elapsed}s] Status: ${status}"

        if [ "$status" = "live" ]; then
            echo "Deploy is live."
            return 0
        fi

        if echo "$status" | grep -qE "$FAILURE_STATES"; then
            echo "::error::Deploy failed with status: ${status}"
            exit 1
        fi

        sleep $POLL_INTERVAL
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    echo "::error::Deploy timed out after ${POLL_TIMEOUT}s"
    exit 1
}
