# Deployment checklist

Before declaring any application "done", verify every item.
This applies to new apps and upgrades alike.

## Version consistency

- [ ] If using a pinned image tag, `usage()` help text, script default
  variable, and container image tag all reference the same version,
  overrideable via `--version` and an env var.
- [ ] If using a floating tag (e.g. `server-cuda`), it's paired with
  `imagePullPolicy: Always` and a regular restart cadence.

## YAML manifests

- [ ] Every YAML file containing `${VAR}` placeholders is processed through
  `envsubst` + temp file (with `trap` cleanup) in `install.sh`, never
  `kubectl apply -f` directly.
- [ ] `kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`
  pattern used for Secrets and other generated resources for idempotency.

## Idempotency

- [ ] Re-running `install.sh` produces a no-op: all `kubectl apply` calls
  report "unchanged" or "configured" with no resource recreation.

## Post-deploy verification

- [ ] `kubectl logs -n <ns> deployment/<name>` shows no E/F-level errors.
- [ ] Pod status is `Running` with all containers `Ready`.
- [ ] The script's final summary echoes the version or image tag that was
  actually deployed.
- [ ] `kubectl get httproute -n <ns>` shows the route accepted and bound to
  a Gateway (check the Route status conditions).

## Cluster sync

- [ ] Every resource running in the cluster has a corresponding manifest file
  in this repo. No resource exists only on the cluster.
- [ ] `kubectl get deploy <name> -n <ns> -o jsonpath='{.spec.template.spec.containers[0].image}'`
  matches the image tag in the deployment manifest (or version variable, if
  templated).

## Script conventions

- [ ] `SCRIPT_DIR` pattern used for locating sibling files.
- [ ] Secrets use `.example` files with placeholders; real values passed via
  CLI flags or gitignored files.
- [ ] `envsubst` is called with only the specific variables that the template
  needs (e.g. `envsubst '$GATEWAY_HOST'`), not all exported vars.
