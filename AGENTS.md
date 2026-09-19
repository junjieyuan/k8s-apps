# AGENTS.md

## Project nature

This repo manages Kubernetes application workloads running on an existing
k8s cluster. It is NOT responsible for cluster provisioning — that lives
in the **`k8s-cluster`** repo (VM provisioning, kubeadm init/join, CNI/CSI,
GPU operator, cert-manager, external-dns). Only user-facing services and
their resources (deployments, services, gateways, HTTPRoutes, certificates)
live here.

**The repo must be in full sync with the cluster** — every application
resource running in the cluster must have a corresponding manifest or
values file in this repo. No manual `kubectl` edits on the cluster that
aren't reflected back into code. When in doubt, re-run `kubectl apply -k <app>`
to verify idempotency.

## Directory structure

Each app lives in its own directory. The canonical layout varies by stack:
- **Plain YAML apps** (cloudflared, gateway, postgres, llama-server,
  keycloak, keycloak-operator) — described in detail under Shell & tools.
  Direct deploy: `kubectl apply -k <app>/`.
- **Helm + Kustomize apps** (headlamp, monitoring) — described in detail
  under Shell & tools. Deploy: `kubectl kustomize --enable-helm <app>/ |
  kubectl apply -f -`.

Shared infrastructure (Gateway, Certificate) lives in `gateway/`.

## Conventions

### Documentation

- **Keep docs in sync with code.** When changing deployment commands,
  secret management, directory structure, or conventions, update these
  files in the same commit or a follow-up:
  - `AGENTS.md` — if conventions change
  - `README.md` — if deploy commands, app list, or architecture change
  - **Update this doc** if verification steps change
  - `.gitignore` — if new ignored file patterns are introduced

### Shell & tools

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail`. Never
  introduce Python, Node, or other languages.
- **Check runtime deps** with `command -v` early in the script, before any
  work begins. Never assume `helm`, `kubectl`, or other tools are present.
- **`kubectl` is the primary tool** for resource management.
  - **Kustomize** (`kubectl apply -k`) is the default for all plain YAML
    apps. Variable injection (namespace, image tag) lives in
    `kustomization.yaml` via `namespace:` and `images.newTag:`. Plain YAML
    files contain no `${VAR}` placeholders. Secrets use `secretGenerator`
    with `.env` files (real values gitignored, `.env.example` committed as
    template). Multi-environment apps use `base/` + `overlays/<env>/`.
  - **`helmCharts` generator** — when a Kustomization uses the built-in
    `helmCharts` field, it requires `--enable-helm`. **`kubectl apply -k`
    does NOT support `--enable-helm`**, so you must pipe:
    `kubectl kustomize --enable-helm <dir>/ | kubectl apply -f -`.
    `kustomize build --enable-helm <dir>/ | kubectl apply -f -` also works
    if standalone kustomize is installed. Version pinning goes in the
    `helmCharts[].version` field; overrides in `valuesFile`. The generator
    renders only `templates/`, never `crds/`, so chart CRDs are not in
    the deploy stream; deploy them per the project's CRD upgrade
    documentation (e.g. kube-prometheus-stack: the chart repo's
    UPGRADE.md).
- **Helm** is used **only** via the Kustomize `helmCharts` generator
  — never `helm install` directly. This applies to complex charts
  (kube-prometheus-stack) and simple ones alike. The single exception is
  a Helm chart that ships interdependent CRDs/sub-resources which
  `helm template` handles but plain YAML cannot express concisely. For
  a simple deployment + service + route, use plain Kustomize without
  `helmCharts`.
- **KYAML for all YAML** — every `*.yaml` file in this repo is written in
  KYAML, the flow-style YAML dialect from KEP 5295 (see KYAML style below).
  Format with Google's `yamlfmt` using the repo-root `.yamlfmt` config:
  `yamlfmt <file>` applies, `yamlfmt -dry <file>` previews, and
  `yamlfmt -lint <dir>` is the CI/enforcement check.
- **`SCRIPT_DIR` pattern** — `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
  for locating sibling files.

### Drift prevention

The repo is the source of truth for every resource. Runtime state must never
be changed with one-off commands:

- **Never use `kubectl scale`, `kubectl edit`, `kubectl patch`, or `kubectl
  delete` to mutate manifest-managed resources** (deployments, services,
  PVCs/PVs, routes, namespaces, ...). These change the cluster without a
  manifest, and the next `kubectl apply -k` silently reverts them — the repo
  and cluster drift apart.
- **Pods are exempt: they are controller-managed and never live in the repo.**
  Deleting a pod is remediation, not drift — the Deployment/ReplicaSet
  recreates it. Safe targets: stale `Unknown` pods after a node reboot (they
  still count toward replicas and block the replacement until removed),
  stuck `Terminating`, CrashLoopBackOff. Verify node/workload state first,
  and only delete pods owned by a controller with a manifest — mind pods with
  node-local/RWO volumes whose replacement may not start elsewhere.
- **Read-only inspection is always allowed** — `get`, `describe`, `logs`,
  `events`, `top`, `port-forward`. `exec` is for inspection only: never modify
  files under mounted volumes (that would be unreflected state).
- **Rollout operations are exempt** — `kubectl rollout restart|status|undo`
  do not change the declared spec (restart only stamps an annotation) and are
  the approved way to force a reload after config/secret changes.
- **Node maintenance is not drift** — `cordon`/`uncordon`/`drain` change
  scheduling, not manifests. Coordinate with k8s-cluster: node lifecycle
  lives in that repo.
- **Replica counts live in the manifests.** To scale an app, edit `replicas:`
  in its `deployment.yaml`, commit, then `kubectl apply -k <app>/`. Re-running
  the apply is the idempotency check.
- **GPU apps are mutually exclusive** — llama-server, comfyui, and vox
  share one RTX 4080 (16GB) and cannot run inference at the same time.
  Switching the GPU owner means editing `replicas:` in the deployments
  (1 for the owner, 0 for the others) and applying each app. Never
  `kubectl scale` to switch.
- **Decommissioning** — to remove an app, run `kubectl delete -k <app>/`
  first (while the manifests are still in the repo), then delete the
  manifests and commit. Plain `kubectl apply -k` never deletes resources that
  disappear from manifests. Never `kubectl delete` PVCs/PVs ad-hoc — that is
  data loss, not drift.
- **No ad-hoc test resources** — throwaway namespaces/pods/objects outside the
  repo violate the sync invariant; if temporary resources are unavoidable,
  clean them up before finishing.

### Secrets

- **Separate secrets from code.** Real values live in gitignored files
  (`.env`, `secret.yaml`, credentials, etc.). Committed files use `.example`
  variants with placeholder values only. Never commit keys, passwords,
  tokens, certificates, credentials, or kubeconfig files.
- **Kustomize `secretGenerator`** is the preferred approach for plain YAML
  apps. It reads from `.env` and generates a hashed Secret at build time,
  automatically patching all `secretRef.name` references in downstream
  resources.
- **`values-secret.yaml`** for `helmCharts` apps — sensitive Helm values
  (passwords, tokens) go in a gitignored `values-secret.yaml` loaded via
  `additionalValuesFiles`. Commit `values-secret.yaml.example` with
  placeholder values as a template.
- `models.ini` may contain public HuggingFace repo references — that is fine.

### Versioning

- **Pin explicit versions** (e.g. `2026.6.1`, `server-cuda12-b9894`, not
  `latest`), but keep them current. Check upstream releases before deployment.
  - Plain Kustomize apps: pin via `images.newTag:` in `kustomization.yaml`.
  - `helmCharts` apps: pin via `helmCharts[].version` in `kustomization.yaml`.
- **Container images** — pin in `images.newTag` as `tag@digest` (tag for
  humans, digest authoritative for pulls).
- **Digest maintenance** — on a tag bump update BOTH halves of `newTag`.
  The digest is the `Docker-Content-Digest` the registry returns for the
  tag (`crane digest`, or the registry API header). A tag-only bump keeps
  pulling the old artifact — digest wins.
- **Gateway API** — CRD version must match the version supported by the CNI
  (Cilium) and the `gateway.networking.k8s.io` API version used in manifests.

### KYAML style

All YAML in this repo is **KYAML** — the strict flow-style YAML dialect
proposed in KEP 5295 and explained in the Kubernetes blog post
[How to Pretty-Print Your Kubernetes YAML as KYAML](https://kubernetes.io/blog/2026/08/11/how-to-pretty-print-kubernetes-yaml-as-kyaml/).
Every KYAML file is valid YAML, so `kubectl`, Kustomize, and Helm consume it
unchanged.

- **Structure is explicit, not indentation-dependent** — maps use `{}`,
  lists use `[]`, string values are double-quoted (no silent type coercion),
  trailing commas are kept, and each document starts with a `---` header.
  Comments are allowed, unlike JSON.
- **Format with `yamlfmt`** — Google's `yamlfmt` with the repo-root `.yamlfmt`
  config (`formatter.type: kyaml`). Preview with
  `yamlfmt -dry <file>`, apply with `yamlfmt <file>` (or `yamlfmt <dir>`),
  enforce with `yamlfmt -lint`.
- **No redundant defaults** — omit YAML fields that match Kubernetes defaults
  (e.g. `protocol: TCP`, `replicas: 1`, `terminationGracePeriodSeconds:
  30`). Only include explicit overrides so intentional deviations stand out.
- **Comments explain why, not what** — the manifest itself is the what; a
  comment should capture the decision or constraint that isn't visible in the
  YAML (e.g. why `clusterIP`, why a pinned size).
- **helmCharts values: omit chart defaults too** — the same "no redundant
  defaults" rule applies to values files: drop keys that match the pinned
  chart version's defaults and keep only intentional overrides.
- **Validate chart value keys** — misspelled or wrongly nested values are
  silently ignored by Helm. Check keys against the pinned chart version
  (`helm show values <chart> --version <v>`) and confirm the effect with
  `kubectl diff` after applying.
- **Not YAML** — `.env*` files are dotenv input for Kustomize
  `secretGenerator`, and `*.json` files (e.g. `credentials.json.example`)
  stay JSON. App-input data files mounted into pods (e.g.
  `vox/qwen3_tts.yaml`, the vLLM-Omni deploy config) keep the upstream
  format and are excluded from KYAML lint via `.yamlfmt`. Vendored Helm
  chart sources under gitignored `*/charts/` are
  third-party and are not reformatted. Dated plan docs under
  `docs/superpowers/plans/` are historical records; their inline examples
  keep the YAML style from when the plan was written.

### Gateway design

- **Dedicated namespace** — the shared Gateway lives in `gateway/`, never
  inside an application namespace.
- **Gateway API over Ingress** — use `Gateway` + `HTTPRoute` from
  `gateway.networking.k8s.io/v1`.
- **TLS via cert-manager** — `ClusterIssuer` + `Certificate` for automatic
  Let's Encrypt provisioning and renewal.
- **Wildcard TLS** — a single `*.domain` certificate covers all app hostnames
  and requires no changes when adding new apps. Needs a DNS-01 solver
  (configured in `k8s-cluster`).
- **IP pinning** — in bare-metal environments without BGP, pin the LB IP via
  `spec.addresses` so it survives Gateway deletion and recreation.
- **Cloudflare proxy is the global default** — external-dns in `k8s-cluster`
  runs with `--cloudflare-proxied`, so every DNSEndpoint is proxied unless
  overridden. To make a specific record DNS-only, set `providerSpecific` with
  the full annotation key `external-dns.alpha.kubernetes.io/cloudflare-proxied`
  and value `"false"` — the value is the string `"true"`/`"false"`, not a YAML
  boolean.
- **Cross-namespace routes** — HTTPRoutes reference the Gateway via
  `parentRefs.namespace`. The Gateway's `allowedRoutes.namespaces.from:
  All` enables this without per-app ReferenceGrants.

### Keycloak (Keycloak Operator)

`keycloak/` is plain YAML, but the workload is a `Keycloak` CR
(`k8s.keycloak.org/v2beta1`) managed by the Keycloak Operator installed by
`keycloak-operator/` (deploy it first: `kubectl apply -k keycloak-operator/`).

- **Operator-owned resources have no repo manifest** — the operator creates
  and owns the StatefulSet `keycloak`, Services `keycloak-service`
  (8080/9000) and `keycloak-discovery` (7800), and the
  `KeycloakRealmImport` lifecycle. The CR is the manifest of record: change
  the CR (or the operator app) and let the operator reconcile; never
  `kubectl edit/patch/delete` operator-owned objects (same exemption as
  pods — the controller recreates/repairs them).
- **`keycloak/transformer-config.yaml`** (loaded via `configurations:` in
  the kustomization — it is a transformer-config file, not a kustomization
  field) rewrites the CR's `secretGenerator` references —
  `spec/db/usernameSecret/name`, `spec/db/passwordSecret/name`,
  `spec/bootstrapAdmin/user/secret` — to the generated hashed secret names.
  Plain KYAML cannot express this any other way.
- **Bootstrap / fresh-DB rebuild** — the `keycloak-operator` master-realm
  user (operator login AND rebuild bootstrap) comes from
  `.env-operator-admin` (secret `keycloak-operator-admin`; fixed keys
  `username`/`password`). On a fresh database the Keycloak pod bootstraps
  that user on first start via KC_BOOTSTRAP_ADMIN_*, which is what lets the
  operator authenticate. After any fresh-DB rebuild, recreate
  `platform-admin` (the permanent human admin) via kcadm — it is NOT
  bootstrapped.
- **One-shot realm imports** — CRs under `keycloak/realms/` are applied
  explicitly (`kubectl apply -f`; the namespace is in the file), NOT via
  `-k`. When `status.conditions` shows `Done=True` and `HasErrors=False`,
  delete the CR (`kubectl delete keycloakrealmimport -n keycloak <name>`);
  the realm persists in the database and the file stays in the repo as the
  rebuild vehicle.

## Deployment checklist

Before declaring any application "done", verify every item.
This applies to new apps and upgrades alike.

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
  `admission-create` Job has a TTL, so it always diffs as a create.
- **Post-deploy** — `kubectl logs -n <ns> deployment/<name>` shows no E/F errors; CrashLoopBackOff investigated. `kubectl get pods -n <ns>` shows Running+Ready with RESTARTS=0. `kubectl get httproute -n <ns>`: `status.parents[].conditions` shows `Accepted=True`, `ResolvedRefs=True`.
- **Cluster sync** — every running resource has a manifest (exception:
  operator-owned resources, see Keycloak (Keycloak Operator) above).
- **Committed** — the change is committed (see Commit conventions); an
  uncommitted app change leaves the repo out of sync with the cluster.

## Commit conventions

- Atomic commits following [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
- Each commit changes one logical concern.
- Subject: the concise *what*, imperative mood.
- Body: the *why* — motivation, constraints, and decisions the diff cannot
  show (related issue/PR refs, `BREAKING CHANGE` notes). Omit the body
  entirely when the diff is self-explanatory.
- Wrap the commit message subject at ~50 chars and body lines at ~72 chars.
