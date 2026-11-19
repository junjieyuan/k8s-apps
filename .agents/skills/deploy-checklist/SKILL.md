---
name: deploy-checklist
description: Mandatory deployment checklist for this k8s-apps repo. Use before declaring any application "done" after a new app, an upgrade, or any kubectl apply/rollout in this repo, and whenever verifying the final state of an app in the cluster.
---

# Deployment checklist

Before declaring any application "done", verify every item below.
This applies to new apps and upgrades alike. The repo conventions these
checks reference (KYAML, `secretGenerator`, `values-secret.yaml`, the
`helmCharts` generator, commit conventions) are defined in `AGENTS.md`.

- **Version consistency** — the rendered image equals the pinned
  reference — `kubectl kustomize <app>/ | grep image:` (`--enable-helm`
  for helmCharts apps); a rendered image without tag/digest means the
  `images` transformer didn't match (silent failure) — check
  `images[].name` against the deployment's image.
- **KYAML formatting** — every `*.yaml` in the change is KYAML-formatted; `yamlfmt -lint <app>/` passes (or `yamlfmt -dry` shows no diff).
- **Manifests** — no `${VAR}` placeholders in non-kustomize YAML. Secrets use `secretGenerator` (plain) or `values-secret.yaml` (helmCharts).
- **Idempotency** — re-running the deploy command changes nothing. The check
  is an empty diff, not the `apply` verb (it reports `configured` for
  deployment/httproute even when nothing changed): `kubectl diff -k <app>/`
  (plain apps) or `kubectl kustomize --enable-helm <app>/ | kubectl diff -f -`
  (helmCharts apps) must show no output. Known exception: the monitoring
  admission hook Jobs (`admission-create`, `admission-patch`) have a TTL,
  so they always diff as creates.
- **Post-deploy** — `kubectl logs -n <ns> deployment/<name>` shows no E/F errors; CrashLoopBackOff investigated. `kubectl get pods -n <ns>` shows Running+Ready with RESTARTS=0. `kubectl get httproute -n <ns>`: `status.parents[].conditions` shows `Accepted=True`, `ResolvedRefs=True`.
- **Cluster sync** — every running resource has a manifest.
- **Committed** — the change is committed (see Commit conventions); an
  uncommitted app change leaves the repo out of sync with the cluster.
