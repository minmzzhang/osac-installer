# Secret Rotation Runbook

## Core principle

**Detection is not remediation.** If a credential ever touched git — even in
a commit that was later reverted, force-pushed over, or merged and quickly
fixed — it must be treated as compromised and rotated at its source. Deleting
it from a file, rewriting history, or adding it to `.gitleaks.toml`'s
allowlist does not invalidate the value itself; only rotating it at the
system that issued it does.

## Immediate-leak checklist

1. **Rotate first.** Use the per-secret-type procedure below to generate a
   new value and push it to the system(s) that consume it.
2. **Confirm the old value no longer works** (e.g. a request authenticated
   with it now gets rejected).
3. **Land the code/config fix** — stop the value from being hardcoded or
   committed going forward.
4. **Update `.gitleaks.toml`** only if the finding was a false positive.
   Never allowlist a real secret instead of rotating it.
5. **Check every other environment** that may have been built from the same
   source (e.g. another cluster imported from the same `realm.json`, or a
   flavor snapshot taken before rotation) — rotating one live instance does
   not automatically fix others provisioned from the same template.

## Per-secret-type procedures

### Keycloak client secret (`osac-controller`, `osac-admin`)

Generated at boot into the `keycloak-client-secrets` Secret by the
`resolve-realm-secrets` init container
([prerequisites/keycloak/service/deployment.yaml](../prerequisites/keycloak/service/deployment.yaml)),
which also substitutes it into the imported `realm.json` (OSAC-2115). Nothing
sensitive is committed — the checked-in file only has placeholder tokens.

To rotate a live cluster's value:

```bash
scripts/rotate-keycloak-secret.sh <client-id> [keycloak-namespace] [installer-namespace]
# e.g.
scripts/rotate-keycloak-secret.sh osac-controller
```

This pushes a new random value to Keycloak via the admin API, updates
`keycloak-client-secrets` and (for `osac-controller`)
`fulfillment-controller-credentials`, and rolls
`deploy/fulfillment-controller`. See the script's header comment for details.

### `keycloak-database-password`

Generated once by the `password-generator` init container in
[prerequisites/keycloak/database/statefulset.yaml](../prerequisites/keycloak/database/statefulset.yaml)
— it only runs if the Secret doesn't already exist.

To rotate:

```bash
oc delete secret keycloak-database-password -n keycloak
oc rollout restart statefulset/keycloak-database -n keycloak
```

The init container will regenerate the Secret on the next pod start. Note
this only changes the Secret's value — if the Postgres user's actual password
in the database itself needs to change too (not just what's expected to
authenticate it), you must also update it in Postgres directly (e.g. via
`ALTER ROLE keycloak WITH PASSWORD ...`) before restarting, or connections
will fail.

### `osac-aap-admin-password`

Set by the AAP Operator itself when AAP is installed
([base/osac-aap/config/base/job.yaml](../base/osac-aap/config/base/job.yaml)
reads it, but does not create it). Rotating this is an AAP Operator/Gateway
admin-credential operation, not something this repo's scripts manage — see
AAP's own documentation for changing the gateway admin password. After
changing it, re-run `scripts/prepare-aap.sh` so the API token step
re-authenticates with the new password.

### `osac-aap-api-token`

Created by [scripts/prepare-aap.sh](../scripts/prepare-aap.sh), which is
idempotent/safe to re-run — it always mints a new AAP gateway token, stores
it in the `osac-aap-api-token` Secret, and updates `OSAC_AAP_URL` on the
`osac-operator`/`bmf-operator` deployments (which triggers a rollout picking
up the refreshed token via the mounted Secret).

```bash
scripts/prepare-aap.sh
```

**Known gap:** this script does not revoke the *old* token through AAP's
gateway API — it remains valid there until it separately expires or is
revoked manually in the AAP gateway UI/API. If the old token leaked, revoke
it there explicitly; re-running the script alone is not sufficient to
invalidate it.

### `cluster-fulfillment-ig` / `network-fulfillment-ig` provider credentials

These are plain Secrets holding third-party credentials (e.g. Netris
password, provider SSH keys) that you create directly from values you obtain
from the provider — see
[docs/helm-deployment-guide.md](helm-deployment-guide.md) for the full
`oc create secret` commands and which keys each one expects.

To rotate:

1. Generate/obtain a new credential at the provider (e.g. reset the Netris
   password, or issue a new SSH keypair).
2. Re-apply the Secret with the new value:
   ```bash
   oc create secret generic cluster-fulfillment-ig \
     --from-literal=NETRIS_PASSWORD=<new-password> \
     ... \
     -n ${NAMESPACE} --dry-run=client -o yaml | oc apply -f -
   ```
3. Restart whatever AAP job/pod consumes it (these are read by AAP
   config-as-code / execution environments at job-run time, so a fresh job
   run picks up the new value — no separate rollout is needed unless a
   long-running pod cached it).
4. Revoke the old credential at the provider once you've confirmed the new
   one works.

### VAST per-tenant storage credentials

Each tenant gets its own VMS Manager (`osac-<tenant>`), created by
[create_tenant_manager.yaml](../base/osac-aap/collections/ansible_collections/osac/templates/roles/vast_storage/tasks/create_tenant_manager.yaml)
with a randomly generated password. That password is stored in two places
that must stay in sync:

- the hub-cluster Secret `vast-tenant-config-<tenant>` (namespace
  `OSAC_STORAGE_CONFIG_NAMESPACE`, default `osac-system`) — the source of
  truth read by `read_tenant_credentials.yaml`
- the per-tenant CSI Secret in the tenant's own namespace, created once by
  `ensure_storage_class.yaml` for the VAST CSI driver to authenticate with

There is currently no scripted rotation helper for this. To rotate manually:

1. Authenticate to the VMS API as admin and `PATCH` the manager
   (`/api/managers/<id>/`) with a new `password`.
2. Update the `tenant_manager_password` key in the hub Secret
   `vast-tenant-config-<tenant>`.
3. Update the `password` key in the tenant's CSI Secret in its own
   namespace.
4. Confirm CSI mount/provisioning still works (restart consuming pods if the
   CSI driver cached the old credential).

Because `create_tenant_manager.yaml` and `ensure_storage_class.yaml` both
short-circuit when they find existing credentials/StorageClasses, re-running
the AAP job alone will **not** rotate this — the Secrets must be updated
directly as above.

## Adding a new secret type to this table

If you add a new hardcoded/generated secret to the codebase, add a section
here describing how to rotate it, following the pattern above: where it's
generated, where it's consumed, and the exact commands to replace it end to
end (including anything downstream that needs to be restarted/re-synced to
pick up the new value).
