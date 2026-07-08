# Deployment checklist

Before declaring any application "done", verify every item.
This applies to new apps and upgrades alike.

## Version consistency

- [ ] Kustomize apps — image tag pinned via `images.newTag:` in
  `kustomization.yaml`. `helmCharts` apps — chart version pinned via
  `helmCharts[].version`.
- [ ] If using a floating tag (e.g. `server-cuda`), it's paired with
  `imagePullPolicy: Always` and a regular restart cadence.

## Manifests

- [ ] No `${VAR}` placeholders in any YAML file. Hostnames, namespaces,
  and versions are hardcoded or managed by Kustomize.
- [ ] Plain YAML apps deploy via `kubectl apply -k <dir>/`.
- [ ] `helmCharts` apps deploy via `kubectl kustomize --enable-helm <dir>/ | kubectl apply -f -`.
- [ ] Secrets — plain apps use `secretGenerator` with gitignored `.env`;
  `helmCharts` apps use gitignored `values-secret.yaml` loaded via
  `additionalValuesFiles`. Both have committed `.example` templates.

## Idempotency

- [ ] Re-running the deploy command produces a no-op: all resources report
  `unchanged` or `configured` with no unintended recreation.

## Post-deploy verification

- [ ] `kubectl logs -n <ns> deployment/<name>` shows no E/F-level errors.
- [ ] Pod status is `Running` with all containers `Ready`.
- [ ] `kubectl get httproute -n <ns>` shows the route accepted and bound to
  a Gateway (check the Route status conditions).

## Cluster sync

- [ ] Every resource running in the cluster has a corresponding manifest file
  in this repo. No resource exists only on the cluster.
- [ ] `kubectl get deploy <name> -n <ns> -o jsonpath='{.spec.template.spec.containers[0].image}'`
  matches the image tag in the deployment manifest.

## Script conventions (bash scripts only)

- [ ] `SCRIPT_DIR` pattern used for locating sibling files.
- [ ] `command -v` checks for required tools before any work begins.
