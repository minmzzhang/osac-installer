#!/usr/bin/env bash
#
# Copyright (c) 2025 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.
#
# Rotates a Keycloak client secret against a live cluster: generates a new
# random value, pushes it to Keycloak via the admin API, updates the
# keycloak-client-secrets Secret (source of truth for setup.sh /
# refresh-after-snapshot.py, see OSAC-2115), and rolls known dependent
# deployments.
#
# Use this any time a client secret is known or suspected to have leaked —
# rotation is the only thing that actually invalidates an exposed value;
# removing it from a file or git history does not.
#
# Usage: scripts/rotate-keycloak-secret.sh <client-id> [keycloak-namespace] [installer-namespace]
#
# Examples:
#   scripts/rotate-keycloak-secret.sh osac-controller
#   scripts/rotate-keycloak-secret.sh osac-admin keycloak osac

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

CLIENT_ID="${1:?Usage: $0 <client-id> [keycloak-namespace] [installer-namespace]}"
KEYCLOAK_NS="${2:-keycloak}"
INSTALLER_NAMESPACE="${3:-${INSTALLER_NAMESPACE:-osac}}"
REALM="osac"

# keycloak-client-secrets stores one key per client, named after the literal
# client ID (e.g. "osac-controller"), matching the resolve-realm-secrets init
# container in prerequisites/keycloak/service/deployment.yaml.
NEW_SECRET=$(openssl rand -base64 18)

echo "=== Rotating Keycloak client secret ==="
echo "Client: ${CLIENT_ID}"
echo "Keycloak namespace: ${KEYCLOAK_NS}"
echo ""

KC_URL="https://$(oc get route keycloak -n "${KEYCLOAK_NS}" -o jsonpath='{.spec.host}')"
KC_ADMIN_TOKEN=$(curl -sk "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "username=admin" -d "password=admin" -d "grant_type=password" | jq -r '.access_token')
[[ -n "${KC_ADMIN_TOKEN}" && "${KC_ADMIN_TOKEN}" != "null" ]] || { echo "ERROR: Could not get Keycloak admin token" >&2; exit 1; }

echo "[1/3] Fetching current client representation..."
CLIENT_JSON=$(curl -sk -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" \
    "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" | jq -c '.[0] // empty')
[[ -n "${CLIENT_JSON}" ]] || { echo "ERROR: Client '${CLIENT_ID}' not found in the ${REALM} realm" >&2; exit 1; }
CLIENT_UUID=$(echo "${CLIENT_JSON}" | jq -r '.id')

# PUT replaces the full client representation in Keycloak's admin API, so we
# mutate only the secret field on the representation we just fetched rather
# than pushing a partial/synthetic body.
UPDATED_CLIENT_JSON=$(echo "${CLIENT_JSON}" | jq --arg s "${NEW_SECRET}" '.secret = $s')

echo "[2/3] Pushing new secret to Keycloak (client UUID: ${CLIENT_UUID})..."
curl -sk -X PUT -H "Authorization: Bearer ${KC_ADMIN_TOKEN}" -H "Content-Type: application/json" \
    "${KC_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}" \
    -d "${UPDATED_CLIENT_JSON}" >/dev/null

echo "[3/3] Updating keycloak-client-secrets and dependent app secrets..."
oc patch secret keycloak-client-secrets -n "${KEYCLOAK_NS}" --type=merge \
    -p "{\"data\":{\"${CLIENT_ID}\":\"$(printf '%s' "${NEW_SECRET}" | base64 -w0)\"}}"

if [[ "${CLIENT_ID}" == "osac-controller" ]]; then
    oc create secret generic fulfillment-controller-credentials \
        --from-literal=client-id="${CLIENT_ID}" \
        --from-literal=client-secret="${NEW_SECRET}" \
        -n "${INSTALLER_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -
    echo "  Rolling fulfillment-controller to pick up the new secret..."
    oc rollout restart deploy/fulfillment-controller -n "${INSTALLER_NAMESPACE}" 2>/dev/null || \
        echo "  WARNING: could not restart deploy/fulfillment-controller in ${INSTALLER_NAMESPACE} (not found?) — restart it manually."
fi

echo ""
echo "=== Rotation complete for '${CLIENT_ID}' ==="
echo "Remember to:"
echo "  - Confirm the old secret value no longer authenticates against Keycloak"
echo "  - Update any consumer of this client's secret not covered by this script"
echo "  - If this was in response to a leak, check every other environment that may have"
echo "    imported the same value (e.g. other clusters built from the same realm.json)"
