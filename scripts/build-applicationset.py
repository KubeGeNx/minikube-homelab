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


def main():
    root_dir = os.environ["ROOT_DIR"]
    apps_dir = os.path.join(root_dir, "gitops", "apps")
    out_file = os.environ["OUT_FILE"]

    component_table = os.environ["COMPONENT_TABLE"]
    versions = parse_env_file(open(os.path.join(root_dir, "versions.env")).read())
    components = parse_env_file(open(os.path.join(root_dir, "components.env")).read())

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
                "values": substitute(helm.get("values", ""), versions, filename),
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
                        "syncOptions": ["CreateNamespace=true"],
                    },
                },
            },
        },
    }

    os.makedirs(os.path.dirname(out_file), exist_ok=True)
    with open(out_file, "w") as f:
        f.write(
            "# GENERATED by scripts/build-applicationset.py -- do not edit by hand.\n"
            "# Source of truth: gitops/apps/*.yaml + versions.env + components.env.\n"
        )
        yaml.dump(applicationset, f, default_flow_style=False, sort_keys=False, width=100)

    print(f"Wrote {out_file} with {len(elements)} component(s).")


if __name__ == "__main__":
    main()
