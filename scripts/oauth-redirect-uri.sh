#!/usr/bin/env bash
# Prints the redirect URI the Google OAuth client must list, derived from the
# released manifests in this repo (the HTTPRoute hostname). No cluster needed.
#
#   scripts/oauth-redirect-uri.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
host=$(kubectl kustomize "$REPO_DIR/yscord/overlays/release" \
    | awk '/^kind: HTTPRoute/ { route = 1 } route && /^  hostnames:/ { getline; sub(/^ *- */, ""); print; exit }')
[ -n "$host" ] || { echo "no HTTPRoute hostname in yscord/overlays/release" >&2; exit 1; }
echo "https://$host/login/oauth2/code/google"
