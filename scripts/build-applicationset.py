#!/usr/bin/env python3
"""
Builds ONE Argo CD ApplicationSet from gitops/apps/*.yaml + versions.env +
components.env. The ApplicationSet is the parent resource: its List
generator gets exactly one element per ENABLED component, and its template
stamps out a child Application per element. Argo CD's own
applicationset-controller then owns create/update/delete of those children
to match the list -- flip a flag in components.env, rebuild, re-apply, and
Argo CD adds or prunes the matching child (cascading to its resources via
the resources-finalizer set in the template) on its own. No bash
kubectl-delete loop needed.

Reads its component table from the COMPONENT_TABLE env var (same table
scripts/lib-components.sh defines) so the table lives in exactly one place,
and reads versions.env / components.env directly from ROOT_DIR.
"""
import os
import re
import sys

import yaml


def parse_env_file(text):
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        values[key.strip()] = val.strip()
    return values


def load_env_layered(root_dir, env_name, filename):
    """Repo-root <filename> is the base; environments/<env>/<filename> overrides
    it key by key. An environment therefore only has to list what actually
    differs from the base -- a prod overlay that pins two chart versions is two
    lines, not a copy of the whole file."""
    values = {}
    base_path = os.path.join(root_dir, filename)
    if os.path.isfile(base_path):
        with open(base_path) as f:
            values.update(parse_env_file(f.read()))
    overlay_path = os.path.join(root_dir, "environments", env_name, filename)
    if os.path.isfile(overlay_path):
        with open(overlay_path) as f:
            values.update(parse_env_file(f.read()))
    return values


def deep_merge(base, overlay):
    """Overlay wins. Dicts merge recursively; every other type -- lists
    included -- replaces outright, matching Helm's own `-f` semantics.

    A null in the overlay is preserved as a null rather than deleting the key,
    because null is meaningful in the merged output: Helm removes a chart
    default whose override value is null (see the `metrics: null` in
    gitops/apps/*-otel-*.yaml). Treating it as a delete here would silently
    reinstate the chart default we were trying to drop."""
    if not isinstance(base, dict) or not isinstance(overlay, dict):
        return overlay
    merged = dict(base)
    for key, value in overlay.items():
        merged[key] = deep_merge(merged[key], value) if key in merged else value
    return merged


def substitute(s, versions, filename):
    """Replace ${VAR} from versions.env; unknown VARs are a hard error --
    a silently-unresolved placeholder would otherwise ship a literal
    '${FOO_VERSION}' as a chart targetRevision and only fail at sync time
    (render-apps.sh already enforces this; the builder must too)."""
    if not isinstance(s, str):
        return s

    unresolved = [v for v in re.findall(r"\$\{([A-Z_]+)\}", s) if v not in versions]
    if unresolved:
        print(
            f"ERROR: {filename}: placeholder(s) not defined in versions.env: "
            + ", ".join(sorted(set(unresolved))),
            file=sys.stderr,
        )
        sys.exit(1)
    return re.sub(r"\$\{([A-Z_]+)\}", lambda m: versions[m.group(1)], s)


def apply_values_overlay(values_str, env_dir, app, versions):
    """Deep-merge environments/<env>/values/<component>.yaml over the base values
    from gitops/apps/<file>.yaml.

    Argo CD's source here is a chart repo rather than git, so `helm.valueFiles`
    can't reach a path in this repo -- merging in the builder is the seam that
    actually exists, and it already owns the ${VAR} substitution pass.

    With no overlay present the base string is returned untouched, so the
    rendered output stays byte-identical to the pre-overlay behaviour and keeps
    the base file's comments. Merging has to round-trip through PyYAML, which
    drops them."""
    overlay_path = os.path.join(env_dir, "values", f"{app}.yaml")
    if not os.path.isfile(overlay_path):
        return values_str

    with open(overlay_path) as f:
        overlay_raw = substitute(f.read(), versions, overlay_path)

    merged = deep_merge(yaml.safe_load(values_str) or {}, yaml.safe_load(overlay_raw) or {})
    print(f"    overlay: environments/.../values/{app}.yaml")
    return yaml.dump(merged, default_flow_style=False, sort_keys=False)


def main():
    root_dir = os.environ["ROOT_DIR"]
    apps_dir = os.path.join(root_dir, "gitops", "apps")
    out_file = os.environ["OUT_FILE"]

    # One environment per cluster. The ApplicationSet keeps the name "platform"
    # in every environment -- renaming it per-env would orphan the existing
    # "platform" ApplicationSet (and its children) on an already-running
    # cluster. The environment is recorded as a label instead.
    env_name = os.environ.get("ENV", "dev")
    env_dir = os.path.join(root_dir, "environments", env_name)
    if not os.path.isdir(env_dir):
        print(
            f"ERROR: unknown environment '{env_name}' -- {env_dir} does not exist.\n"
            f"       Available: {', '.join(sorted(d.name for d in os.scandir(os.path.join(root_dir, 'environments')) if d.is_dir())) or '(none)'}",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"  environment: {env_name}")

    component_table = os.environ["COMPONENT_TABLE"]
    versions = load_env_layered(root_dir, env_name, "versions.env")
    components = load_env_layered(root_dir, env_name, "components.env")

    elements = []
    for line in component_table.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        app, enabled_var, filename, wave = line.split("|")
        enabled = components.get(enabled_var, "true") == "true"
        if not enabled:
            print(f"  skipping {app} (disabled: {enabled_var}={components.get(enabled_var, 'unset')})")
            continue

        path = os.path.join(apps_dir, filename)
        if not os.path.isfile(path):
            print(f"  WARNING: {path} not found for enabled component '{app}', skipping", file=sys.stderr)
            continue

        with open(path) as f:
            doc = yaml.safe_load(f)

        try:
            src = doc["spec"]["source"]
            helm = src.get("helm", {})
            element = {
                "component": app,
                "wave": str(wave),
                "namespace": doc["spec"]["destination"]["namespace"],
                "repoURL": src["repoURL"],
                "chart": src["chart"],
                "targetRevision": substitute(src["targetRevision"], versions, filename),
                "releaseName": helm.get("releaseName", app),
                "values": apply_values_overlay(
                    substitute(helm.get("values", ""), versions, filename),
                    env_dir,
                    app,
                    versions,
                ),
            }
        except (KeyError, TypeError) as exc:
            print(
                f"ERROR: {path} doesn't match the expected Helm Application shape "
                f"(spec.source.repoURL/chart/targetRevision + spec.destination.namespace): {exc!r}",
                file=sys.stderr,
            )
            sys.exit(1)
        elements.append(element)
        print(f"  including {app} (wave {wave}, {element['targetRevision']})")

    if not elements:
        print("ERROR: no enabled components found -- refusing to write an empty ApplicationSet.", file=sys.stderr)
        sys.exit(1)

    applicationset = {
        "apiVersion": "argoproj.io/v1alpha1",
        "kind": "ApplicationSet",
        "metadata": {
            "name": "platform",
            "namespace": "argocd",
            "labels": {"platform-env": env_name},
        },
        "spec": {
            "goTemplate": True,
            "goTemplateOptions": ["missingkey=error"],
            "generators": [
                {"list": {"elements": elements}},
            ],
            "template": {
                "metadata": {
                    "name": "{{.component}}",
                    "namespace": "argocd",
                    "finalizers": ["resources-finalizer.argocd.argoproj.io"],
                    "labels": {"platform-wave": "{{.wave}}"},
                    "annotations": {"argocd.argoproj.io/sync-wave": "{{.wave}}"},
                },
                "spec": {
                    "project": "default",
                    "source": {
                        "repoURL": "{{.repoURL}}",
                        "chart": "{{.chart}}",
                        "targetRevision": "{{.targetRevision}}",
                        "helm": {
                            "releaseName": "{{.releaseName}}",
                            "values": "{{.values}}",
                        },
                    },
                    "destination": {
                        "server": "https://kubernetes.default.svc",
                        "namespace": "{{.namespace}}",
                    },
                    "syncPolicy": {
                        "automated": {"prune": True, "selfHeal": True},
                        # ServerSideApply: large CRDs (e.g. agentgateway's)
                        # exceed the 262144-byte annotation limit that
                        # client-side apply's last-applied-configuration
                        # annotation hits.
                        "syncOptions": ["CreateNamespace=true", "ServerSideApply=true"],
                    },
                },
            },
        },
    }

    os.makedirs(os.path.dirname(out_file), exist_ok=True)
    with open(out_file, "w") as f:
        f.write(
            "# GENERATED by scripts/build-applicationset.py -- do not edit by hand.\n"
            f"# Environment: {env_name}\n"
            "# Source of truth: gitops/apps/*.yaml + versions.env + components.env,\n"
            "# overlaid by environments/<env>/{versions,components}.env and\n"
            "# environments/<env>/values/<component>.yaml.\n"
        )
        yaml.dump(applicationset, f, default_flow_style=False, sort_keys=False, width=100)

    print(f"Wrote {out_file} with {len(elements)} component(s).")


if __name__ == "__main__":
    main()
