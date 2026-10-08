# yscord-deploy

GitOps state of the yscord cluster. Argo CD watches this repo and nothing else;
whatever is on `main` here is what runs.

| Path | Who writes it |
|---|---|
| `apps/` | humans: one Argo CD `Application` per component; `root.yaml` manages them all |
| `argocd/`, `envoy-gateway/` | humans: upstream installs pinned to a version |
| `platform/` | humans: Gateway, EnvoyProxy, Cloudflare tunnel |
| `yscord/` | the release job of [yscord-web](https://github.com/senyaak/yscord-web) only, one commit per release; don't edit by hand |

No secrets live here, not even encrypted ones: Secrets come from an external
store through External Secrets Operator. Which store is this environment's
choice, made in one place (the ClusterSecretStore); the lab uses a local OpenBao
that is not part of this repo.

## New cluster

```fish
scripts/bootstrap.sh --profile <name> [--restore dump.sql]
```

Checks prerequisites (tools, an unsealed secret store holding the secrets, no
other cluster sharing the tunnel), starts minikube, installs Argo CD from
`argocd/`, creates the store credential ("secret zero") and applies
`apps/root.yaml`; Argo CD does the rest. Safe to re-run. `--help` shows how to
move the data from an old cluster.

## Google login

The OAuth client in Google's console must list the redirect URI the app uses.
Google's list can't be read through an API, so print ours and compare:

```fish
scripts/oauth-redirect-uri.sh
```
