#!/usr/bin/env bash
# Bootstraps a minikube cluster for yscord from this repo: after it, Argo CD pulls
# everything else (platform, secrets, the app) from git by itself.
#
# Idempotent: every step checks first and skips what is already done. When a
# step fails, fix what it reports and run the script again.
#
#   scripts/bootstrap.sh --profile yscord [--restore dump.sql]
#
# Moving to a new cluster (one tunnel for all clusters, so only one may run):
#   kubectl --context <old> exec postgres-0 -- sh -c \
#     'pg_dump --clean --if-exists -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > /tmp/yscord-dump.sql
#   minikube stop -p <old>             # kept as a fallback until the new one is verified
#   scripts/bootstrap.sh --profile <new> --restore /tmp/yscord-dump.sql
#   minikube delete -p <old>           # once the site works from the new cluster
#   rm /tmp/yscord-dump.sql
#
# Needs a running, unsealed secret store with the secrets in place; for the lab
# that is the local OpenBao (~/Projects/openbao-local, see its README).
set -euo pipefail

PROFILE=""
RESTORE=""
CPUS=4
MEMORY=4g
BAO=openbao
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)

usage() {
    # The comment block at the top of this file.
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE=$2; shift 2 ;;
        --restore) RESTORE=$2; shift 2 ;;
        --cpus) CPUS=$2; shift 2 ;;
        --memory) MEMORY=$2; shift 2 ;;
        -h | --help) usage ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done
[ -n "$PROFILE" ] || usage 2

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() { printf '   \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '   · %s\n' "$*"; }
die() { printf '   \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
k() { kubectl --context "$PROFILE" "$@"; }
bao() { docker exec "$BAO" bao "$@"; }

# ---------------------------------------------------------------------------
step "Preflight"

for cmd in docker minikube kubectl jq; do
    command -v "$cmd" > /dev/null || die "$cmd is not installed"
done
ok "docker, minikube, kubectl, jq installed"

docker info > /dev/null 2>&1 || die "docker daemon is not running"
ok "docker daemon running"

[ "$(docker inspect -f '{{.State.Running}}' "$BAO" 2> /dev/null)" = true ] \
    || die "secret store container '$BAO' is not running: cd ~/Projects/openbao-local && docker compose up -d"
# `bao status` exits 2 when sealed; the JSON is what matters.
status=$(bao status -format=json 2> /dev/null || true)
[ "$(jq -r .initialized <<< "$status")" = true ] || die "OpenBao is not initialized: see ~/Projects/openbao-local/README.md"
[ "$(jq -r .sealed <<< "$status")" = false ] || die "OpenBao is sealed: docker exec -it $BAO bao operator unseal"
bao token lookup > /dev/null 2>&1 || die "not logged in to OpenBao: docker exec -it $BAO bao login"
ok "OpenBao running, unsealed, logged in"

bao read auth/approle/role/eso > /dev/null 2>&1 || die "AppRole 'eso' missing: see ~/Projects/openbao-local/README.md"
for path in yscord/postgres edge/cloudflared; do
    bao kv get -mount=secret "$path" > /dev/null 2>&1 || die "secret $path missing in OpenBao: see ~/Projects/openbao-local/README.md"
done
ok "AppRole and secrets present"

if [ -n "$RESTORE" ]; then
    [ -s "$RESTORE" ] || die "dump $RESTORE is missing or empty"
    grep -q 'DROP TABLE IF EXISTS' "$RESTORE" \
        || die "dump $RESTORE was taken without --clean --if-exists; it would clash with the tables migrations create"
    ok "dump $RESTORE looks restorable"
fi

# Every cluster runs the same tunnel: two running clusters would split the
# traffic between two databases.
others=$(minikube profile list -o json 2> /dev/null \
    | jq -r --arg p "$PROFILE" '.valid[]? | select(.Name != $p and .Status == "OK") | .Name')
[ -z "$others" ] || die "other clusters running: $others. They share the tunnel; stop them first (minikube stop -p <name>)"
ok "no other cluster running"

# ---------------------------------------------------------------------------
step "Cluster $PROFILE"

if minikube status -p "$PROFILE" > /dev/null 2>&1; then
    ok "already running"
else
    info "starting minikube (a few minutes)"
    # Calico: the default CNI ignores NetworkPolicies.
    minikube start -p "$PROFILE" --driver=docker --cni=calico --cpus="$CPUS" --memory="$MEMORY"
    ok "started"
fi

# Pods reach the store by its container name over the cluster's docker network.
if docker inspect -f '{{json .NetworkSettings.Networks}}' "$BAO" | jq -e --arg p "$PROFILE" 'has($p)' > /dev/null; then
    ok "$BAO already on network $PROFILE"
else
    docker network connect "$PROFILE" "$BAO"
    ok "$BAO connected to network $PROFILE"
fi

# ---------------------------------------------------------------------------
step "Argo CD"

# From this repo, not upstream, so our settings (the Application health check
# that sync waves rely on) exist from the first sync.
k apply -k "$REPO_DIR/argocd" --server-side --force-conflicts > /dev/null
k -n argocd rollout status deploy/argocd-repo-server --timeout=5m > /dev/null
k -n argocd rollout status deploy/argocd-server --timeout=5m > /dev/null
k -n argocd rollout status statefulset/argocd-application-controller --timeout=5m > /dev/null
ok "installed and running"

# ---------------------------------------------------------------------------
step "Secret zero"

k create namespace external-secrets --dry-run=client -o yaml | k apply -f - > /dev/null
if k -n external-secrets get secret openbao-approle > /dev/null 2>&1; then
    ok "openbao-approle already present"
else
    role_id=$(bao read -field=role_id auth/approle/role/eso/role-id)
    # Process substitution: the secret id never shows up in argv.
    k -n external-secrets create secret generic openbao-approle \
        --from-literal=role-id="$role_id" \
        --from-file=secret-id=<(bao write -f -field=secret_id auth/approle/role/eso/secret-id | tr -d '\n') \
        > /dev/null
    ok "openbao-approle created with a fresh secret id"
fi

# ---------------------------------------------------------------------------
step "Root application"

k apply -f "$REPO_DIR/apps/root.yaml" > /dev/null
ok "applied; Argo CD takes it from here"

# ---------------------------------------------------------------------------
if [ -n "$RESTORE" ]; then
    step "Restore $RESTORE"

    if [ "$(k get configmap restore-done -n yscord -o jsonpath='{.data.dump}' 2> /dev/null)" = "$(basename "$RESTORE")" ]; then
        ok "already restored"
    else
        info "waiting for Postgres"
        until k -n yscord get pod postgres-0 > /dev/null 2>&1; do sleep 5; done
        k -n yscord wait pod/postgres-0 --for=condition=Ready --timeout=10m > /dev/null
        ok "Postgres ready"

        # The app keeps the player state in memory and writes all of it every
        # 5 s: running, it would overwrite the restored data. Stop it, but
        # self-heal would scale it back, so pause auto-sync first, the parent
        # (root) before the child it would otherwise revert.
        k -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}' > /dev/null
        until k -n argocd get application yscord > /dev/null 2>&1; do sleep 5; done
        k -n argocd patch application yscord --type merge -p '{"spec":{"syncPolicy":null}}' > /dev/null
        until k -n yscord get deploy yscord > /dev/null 2>&1; do sleep 5; done
        k -n yscord scale deploy/yscord --replicas=0 > /dev/null
        k -n yscord wait pod -l app=yscord --for=delete --timeout=2m > /dev/null 2>&1 || true
        ok "auto-sync paused, app stopped"

        k -n yscord exec -i postgres-0 -- sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
            < "$RESTORE" > /dev/null
        k -n yscord create configmap restore-done --from-literal=dump="$(basename "$RESTORE")" \
            --dry-run=client -o yaml | k apply -f - > /dev/null
        ok "dump restored"
    fi

    # Re-applying root restores its sync policy; root then reverts yscord's,
    # and self-heal scales the app back up.
    k apply -f "$REPO_DIR/apps/root.yaml" > /dev/null
    ok "auto-sync resumed"
fi

# ---------------------------------------------------------------------------
step "Waiting for every application to be Synced and Healthy (up to 15 min)"

deadline=$((SECONDS + 900))
while :; do
    apps=$(k -n argocd get applications -o json)
    pending=$(jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")
        | "\(.metadata.name): \(.status.sync.status // "?")/\(.status.health.status // "?")"' <<< "$apps")
    count=$(jq '.items | length' <<< "$apps")
    if [ -z "$pending" ] && [ "$count" -gt 1 ]; then
        break
    fi
    if [ $SECONDS -ge $deadline ]; then
        die "not healthy after 15 min: $(tr '\n' ' ' <<< "$pending") — look at the Argo CD UI"
    fi
    sleep 10
done
ok "all $count applications Synced and Healthy"

step "Done"
info "context: $PROFILE (kubectl config use-context $PROFILE)"
info "Argo CD UI: kubectl --context $PROFILE -n argocd port-forward svc/argocd-server 8443:443"
info "admin password: kubectl --context $PROFILE -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
