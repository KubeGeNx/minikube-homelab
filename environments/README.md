# Environment overlays

One environment per cluster. `ENV` selects which directory here is layered on
top of the repo-root base files:

```bash
make render ENV=prod
make apply ENV=prod
```

## Layering

| Layer | File | Purpose |
|---|---|---|
| base | `../components.env`, `../versions.env` | Defaults every environment starts from |
| overlay | `<env>/components.env`, `<env>/versions.env` | Key-by-key override; list only what differs |
| base | `../gitops/apps/<n>-<component>.yaml` → `spec.source.helm.values` | Production-shaped Helm values |
| overlay | `<env>/values/<component>.yaml` | Deep-merged over those values |

Deep-merge rules (`scripts/build-applicationset.py:deep_merge`): dicts merge
recursively, **everything else replaces outright** — lists included, matching
Helm's own `-f` semantics. A `null` in an overlay is preserved as a null rather
than deleting the key, because null is meaningful in the output: Helm removes a
chart default whose override value is null.

A component with no overlay file is passed through byte-identically, comments
and all. Merging round-trips through PyYAML, which drops comments — so overlay
only what you actually need to change.

## Which file do I edit?

- **Turning a component on/off for the local dev loop**: `make <component>` /
  `scripts/enable-component.sh`, which writes the *base* `../components.env`.
  The `dev` overlay deliberately carries no component flags, so the base wins
  and today's workflow is unchanged.
- **Turning a component on/off for staging/prod**: add the flag to that
  environment's `components.env`. It overrides the base.
- **Pinning a different chart version per environment** (e.g. prod lags dev by
  a release): add it to that environment's `versions.env`.
- **Changing replica counts, retention, storage, resources**: that environment's
  `values/<component>.yaml`.

## The environments

- **dev** — minikube. Same components and same topology as prod, scaled to one
  replica, short retention, in-cluster SeaweedFS providing the S3 API. It is a
  *profile* of the production architecture, not a simpler one; if something only
  works in dev, that's a bug in the overlay.
- **staging** — production topology at reduced scale. The place to prove an
  upgrade before prod sees it.
- **prod** — full HA. Chart versions are pinned here explicitly rather than
  tracking whatever `update-versions.sh` last wrote to the base.

## Rendered output

The resolved plan, collector config snapshots, and
`gitops/rendered/<env>/applicationset.yaml` are checked in for every
environment. Apply verifies they match their source files before making any
cluster changes. Regenerate with `make render ENV=<env>` and review the diff.
