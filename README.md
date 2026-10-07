# yscord-deploy

GitOps state of the yscord cluster. Argo CD watches this repo and nothing else;
whatever is on `main` here is what runs.

| Path | Who writes it |
|---|---|
| `apps/` | humans: one Argo CD `Application` per component |
| `yscord/` | the release job of [yscord-web](https://github.com/senyaak/yscord-web) only, one commit per release; don't edit by hand |

No secrets live here, not even encrypted ones: Secrets come from OpenBao through
External Secrets Operator.
