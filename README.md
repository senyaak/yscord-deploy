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
