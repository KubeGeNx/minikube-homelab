#!/usr/bin/env python3
"""
Builds a resolved platform plan and ONE Argo CD ApplicationSet from the typed
catalogue, gitops/apps/*.yaml, versions.env, and components.env. The ApplicationSet is the parent resource: its List
generator gets exactly one element per ENABLED component, and its template
stamps out a child Application per element. Argo CD's own
applicationset-controller then owns create/update/delete of those children
to match the list -- flip a flag in components.env, rebuild, re-apply, and
Argo CD adds or prunes the matching child (cascading to its resources via
the resources-finalizer set in the template) on its own. No bash
kubectl-delete loop needed.

Reads install metadata, dependencies, and routes from config/platform-catalog.yaml.
The rendered plan is the shared input for shell apply operations.
"""
import os
import re
import sys
import json
import tempfile

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

    # Only substitute uppercase variable names ending in _VERSION. Helm values
    # can contain runtime placeholders such as ${HOST_IP} in comments or config;
    # those belong to the workload, not the chart-version catalogue.
    unresolved = [v for v in re.findall(r"\$\{([A-Z][A-Z0-9_]*_VERSION)\}", s) if v not in versions]
    if unresolved:
        print(
            f"ERROR: {filename}: placeholder(s) not defined in versions.env: "
            + ", ".join(sorted(set(unresolved))),
            file=sys.stderr,
        )
        sys.exit(1)
    return re.sub(r"\$\{([A-Z][A-Z0-9_]*_VERSION)\}", lambda m: versions[m.group(1)], s)


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

    if app in {"otel-agent", "otel-gateway"}:
        allowed = {
            "resources.requests.cpu", "resources.requests.memory",
            "resources.limits.cpu", "resources.limits.memory",
            "replicaCount", "autoscaling.enabled", "podDisruptionBudget.enabled",
            "statefulset.volumeClaimTemplates",
            "config.processors.tail_sampling.decision_wait",
            "config.processors.tail_sampling.num_traces",
            "config.processors.tail_sampling.expected_new_traces_per_sec",
        }
        overlay = yaml.safe_load(overlay_raw) or {}
        def flatten(node, prefix=""):
            if isinstance(node, dict):
                if not node:
                    yield prefix
                for key, value in node.items():
                    yield from flatten(value, f"{prefix}.{key}" if prefix else str(key))
            else:
                yield prefix
        unknown = sorted(set(flatten(overlay)) - allowed)
        if unknown:
            raise ValueError(f"{overlay_path}: unsupported collector override(s): {', '.join(unknown)}")

    merged = deep_merge(yaml.safe_load(values_str) or {}, yaml.safe_load(overlay_raw) or {})
    print(f"    overlay: environments/.../values/{app}.yaml")
    return yaml.dump(merged, default_flow_style=False, sort_keys=False)


def validate_telemetry_policy(root_dir, collector_configs):
    policy_path = os.path.join(root_dir, "config", "telemetry-policy.yaml")
    with open(policy_path) as f:
        policy = yaml.safe_load(f)
    agent = collector_configs["otel-agent"]
    gateway = collector_configs["otel-gateway"]
    agent_pipelines = agent.get("service", {}).get("pipelines", {})
    gateway_pipelines = gateway.get("service", {}).get("pipelines", {})
    agent_trace = agent_pipelines.get("traces", {})
    processors = agent_trace.get("processors", [])
    required_order = policy["invariants"]["agent_processor_order"]
    for ordered in required_order:
        if ordered not in processors:
            raise ValueError(f"telemetry policy: agent traces pipeline is missing processor '{ordered}'")
    positions = [processors.index(name) for name in required_order]
    if positions != sorted(positions):
        raise ValueError("telemetry policy: agent processors must follow " + " -> ".join(required_order))
    for connector in policy["invariants"]["pre_sampling_connectors"]:
        if connector not in agent_trace.get("exporters", []):
            raise ValueError(f"telemetry policy: agent traces must export to {connector} before sampling")
    allowed_agent_trace_outputs = set(policy["invariants"]["pre_sampling_connectors"] + ["loadbalancing"])
    if set(agent_trace.get("exporters", [])) != allowed_agent_trace_outputs:
        raise ValueError("telemetry policy: agent traces may use only loadbalancing plus pre-sampling connectors")
    derived = agent_pipelines.get("metrics/derived", {})
    if set(derived.get("receivers", [])) != set(policy["invariants"]["pre_sampling_connectors"]):
        raise ValueError("telemetry policy: derived metrics must consume both pre-sampling connectors")
    if policy["invariants"]["derived_metrics_exporter"] not in derived.get("exporters", []):
        raise ValueError("telemetry policy: derived metrics must be sent to the declared metrics store")
    gateway_processors = gateway_pipelines.get("traces", {}).get("processors", [])
    gateway_order = policy["invariants"]["gateway_processor_order"]
    if any(name not in gateway_processors for name in gateway_order):
        raise ValueError("telemetry policy: gateway traces pipeline must include " + " -> ".join(gateway_order))
    if [gateway_processors.index(name) for name in gateway_order] != sorted(gateway_processors.index(name) for name in gateway_order):
        raise ValueError("telemetry policy: gateway processors must follow " + " -> ".join(gateway_order))
    if gateway_pipelines.get("traces", {}).get("exporters") != ["routing"]:
        raise ValueError("telemetry policy: gateway trace pipeline must route sampled traces")
    expected_tenants = policy["invariants"]["tenant_exporters"]
    if set(gateway.get("exporters", {})) != set(expected_tenants):
        raise ValueError("telemetry policy: gateway may export traces only to the declared tenant exporters")
    for pipeline, exporter in (("traces/agents", "otlp/tempo"), ("traces/content", "otlp/tempo-content")):
        if gateway_pipelines.get(pipeline, {}).get("exporters") != [exporter]:
            raise ValueError(f"telemetry policy: {pipeline} must export only through {exporter}")
        actual = gateway.get("exporters", {}).get(exporter, {}).get("headers", {}).get("X-Scope-OrgID")
        if actual != expected_tenants[exporter]:
            raise ValueError(f"telemetry policy: {exporter} tenant must be '{expected_tenants[exporter]}'")
    routing = gateway.get("connectors", {}).get("routing", {})
    table = routing.get("table", [])
    if routing.get("default_pipelines") != ["traces/agents"] or not any(
        rule.get("condition") == 'attributes["gen_ai.capture.content"] == true'
        and rule.get("pipelines") == ["traces/content"] for rule in table
    ):
        raise ValueError("telemetry policy: default/content routing must select agents/agents-content tenants")
    collector_configs["otel-agent"] = agent
    collector_configs["otel-gateway"] = gateway


def build_plan(root_dir, env_name, versions, components):
    """Resolve the typed platform catalogue before producing any side effects."""
    catalog_path = os.path.join(root_dir, "config", "platform-catalog.yaml")
    with open(catalog_path) as f:
        catalog = yaml.safe_load(f)
    entries = catalog.get("components", {})
    for name, item in entries.items():
        manifest = item.get("manifest")
        if manifest and not os.path.isfile(os.path.join(root_dir, manifest)):
            raise ValueError(f"catalogue entry '{name}' references missing manifest '{manifest}'")
        if manifest:
            with open(os.path.join(root_dir, manifest)) as f:
                manifest_doc = yaml.safe_load(f)
            spec = manifest_doc.get("spec", {})
            source = spec.get("source", {})
            if item.get("adapter") == "helm":
                required = (source.get("repoURL"), source.get("chart"), source.get("targetRevision"), spec.get("destination", {}).get("namespace"), item.get("wave"))
                if not all(required):
                    raise ValueError(f"catalogue Helm entry '{name}' manifest lacks chart source, destination namespace, or wave")
                item["namespace"] = spec["destination"]["namespace"]
            elif item.get("adapter") == "argocd-git":
                required = (source.get("repoURL"), source.get("path"), source.get("targetRevision"), item.get("namespace"))
                if not all(required):
                    raise ValueError(f"catalogue git entry '{name}' manifest lacks source, target revision, or namespace")
        handler = item.get("handler")
        if handler and not os.path.isfile(os.path.join(root_dir, handler)):
            raise ValueError(f"catalogue entry '{name}' references missing handler '{handler}'")
        version_key = item.get("version")
        if version_key and version_key not in versions:
            raise ValueError(f"catalogue entry '{name}' references missing version '{version_key}'")
    for name, item in entries.items():
        flag = item.get("flag")
        value = components.get(flag, "true").lower()
        if value not in {"true", "false"}:
            raise ValueError(f"{flag} must be 'true' or 'false' (got {value!r})")
        if item.get("adapter") not in {"helm", "script", "argocd-git"}:
            raise ValueError(f"catalogue entry '{name}' has unsupported adapter {item.get('adapter')!r}")
        for dependency in item.get("dependencies", []):
            if dependency not in entries:
                raise ValueError(f"catalogue entry '{name}' references unknown dependency '{dependency}'")
    complete, stack = set(), []

    def validate_acyclic(name):
        if name in stack:
            cycle = stack[stack.index(name):] + [name]
            raise ValueError("dependency cycle: " + " -> ".join(cycle))
        if name in complete:
            return
        stack.append(name)
        for dependency in entries[name].get("dependencies", []):
            validate_acyclic(dependency)
        stack.pop()
        complete.add(name)

    for name in entries:
        validate_acyclic(name)
    requested = [
        name for name, item in entries.items()
        if components.get(item["flag"], "true").lower() == "true"
    ]
    disabled = {
        name for name, item in entries.items()
        if components.get(item["flag"], "true").lower() == "false"
    }
    resolved, visiting, provenance = [], [], {}

    def visit(name, requested_by):
        if name not in entries:
            raise ValueError(f"catalogue dependency '{name}' is not defined")
        if name in visiting:
            cycle = visiting[visiting.index(name):] + [name]
            raise ValueError("dependency cycle: " + " -> ".join(cycle))
        if name in resolved:
            if requested_by:
                provenance.setdefault(name, set()).add(requested_by)
            return
        visiting.append(name)
        item = entries[name]
        for dependency in item.get("dependencies", []):
            if dependency in disabled:
                raise ValueError(
                    f"dependency chain {' -> '.join(visiting + [dependency])} reaches explicitly disabled entry "
                    f"'{dependency}' "
                    f"(flag {entries[dependency]['flag']}=false); enable it in "
                    f"components.env or environments/{env_name}/components.env"
                )
            visit(dependency, name)
        visiting.pop()
        resolved.append(name)
        if requested_by:
            provenance.setdefault(name, set()).add(requested_by)

    for name in requested:
        visit(name, None)

    route_list = []
    for route in catalog.get("routes", []):
        flag = route["flag"]
        if flag != "ALWAYS" and flag not in {item["flag"] for item in entries.values()}:
            raise ValueError(f"route '{route['file']}' references unknown flag '{flag}'")
        if not os.path.isfile(os.path.join(root_dir, "gitops", "platform", "routes", route["file"])):
            raise ValueError(f"catalogue route file not found: {route['file']}")
        route_list.append({"file": route["file"], "enabled": flag == "ALWAYS" or components.get(flag, "true").lower() == "true", "flag": flag})

    namespaces = {}
    for name in resolved:
        item = entries[name]
        manifest = item.get("manifest")
        if manifest:
            with open(os.path.join(root_dir, manifest)) as f:
                doc = yaml.safe_load(f)
            namespace = doc.get("spec", {}).get("destination", {}).get("namespace")
        else:
            namespace = item.get("namespace")
        if not namespace:
            raise ValueError(f"catalogue entry '{name}' has no destination namespace")
        item["namespace"] = namespace
        namespaces[name] = namespace

    return {
        "environment": env_name,
        "requested": sorted(requested),
        "dependency_enabled": [name for name in resolved if name not in requested],
        "enabled": resolved,
        "namespaces": namespaces,
        "routes": route_list,
        "versions": versions,
        "catalogue_version": catalog.get("version", 1),
        "provenance": {name: sorted(parents) for name, parents in provenance.items()},
        "entries": entries,
    }


def main():
    root_dir = os.environ["ROOT_DIR"]
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

    versions = load_env_layered(root_dir, env_name, "versions.env")
    components = load_env_layered(root_dir, env_name, "components.env")

    try:
        plan = build_plan(root_dir, env_name, versions, components)
    except (OSError, KeyError, TypeError, ValueError) as exc:
        print(f"ERROR: cannot build platform plan: {exc}", file=sys.stderr)
        sys.exit(1)

    plan_path = os.path.join(os.path.dirname(out_file), "platform-plan.json")
    plan_for_json = {key: value for key, value in plan.items() if key != "entries"}
    plan_for_json["entries"] = plan["entries"]

    elements = []
    collector_configs = {}
    enabled_set = set(plan["enabled"])
    for app, item in plan["entries"].items():
        if app not in enabled_set:
            continue
        if item["adapter"] != "helm":
            continue
        path = os.path.join(root_dir, item["manifest"])
        if not os.path.isfile(path):
            raise SystemExit(f"ERROR: catalogue manifest not found for '{app}': {path}")

        with open(path) as f:
            doc = yaml.safe_load(f)

        try:
            src = doc["spec"]["source"]
            helm = src.get("helm", {})
            values_str = apply_values_overlay(
                substitute(helm.get("values", ""), versions, item["manifest"]),
                env_dir,
                app,
                versions,
            )
            values_obj = yaml.safe_load(values_str) or {}
            if app in {"otel-agent", "otel-gateway"}:
                collector_configs[app] = values_obj.get("config", {})
            element = {
                "component": app,
                "wave": str(item["wave"]),
                "namespace": item["namespace"],
                "repoURL": src["repoURL"],
                "chart": src["chart"],
                "targetRevision": substitute(src["targetRevision"], versions, item["manifest"]),
                "releaseName": helm.get("releaseName", app),
                "values": values_str,
            }
        except (KeyError, TypeError) as exc:
            print(
                f"ERROR: {path} doesn't match the expected Helm Application shape "
                f"(spec.source.repoURL/chart/targetRevision + spec.destination.namespace): {exc!r}",
                file=sys.stderr,
            )
            sys.exit(1)
        elements.append(element)
        print(f"  including {app} (wave {item['wave']}, {element['targetRevision']})")

    if not elements:
        print("ERROR: no enabled components found -- refusing to write an empty ApplicationSet.", file=sys.stderr)
        sys.exit(1)
    if set(collector_configs) != {"otel-agent", "otel-gateway"}:
        # Both collector tiers share one enablement flag and must be generated
        # together; fail closed if a catalogue edit accidentally splits them.
        if any(name in plan["enabled"] for name in ("otel-agent", "otel-gateway")):
            raise ValueError("telemetry policy: agent and gateway must be enabled and generated together")
    else:
        validate_telemetry_policy(root_dir, collector_configs)

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
                    # Ignore the observed PVC-template status and rollout
                    # restart timestamp. Kubernetes records the former under
                    # StatefulSet spec, while our observability-level script
                    # deliberately writes the latter to restart collectors.
                    "ignoreDifferences": [{
                        "group": "apps",
                        "kind": "StatefulSet",
                        "jsonPointers": ["/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt"],
                        "jqPathExpressions": [".spec.volumeClaimTemplates[0].status"],
                    }],
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
                        "syncOptions": ["CreateNamespace=true", "ServerSideApply=true", "RespectIgnoreDifferences=true"],
                    },
                },
            },
        },
    }

    appset_text = (
        "# GENERATED by scripts/build-applicationset.py -- do not edit by hand.\n"
        f"# Environment: {env_name}\n"
        "# Source of truth: config/platform-catalog.yaml, gitops/apps/*.yaml,\n"
        "# versions.env, components.env, and environment overlays.\n"
        + yaml.dump(applicationset, default_flow_style=False, sort_keys=False, width=100)
    )
    artifacts = {
        out_file: appset_text,
        plan_path: json.dumps(plan_for_json, indent=2, sort_keys=True) + "\n",
    }
    if collector_configs:
        for tier, config in collector_configs.items():
            path = os.path.join(os.path.dirname(out_file), f"{tier}-config.yaml")
            artifacts[path] = (
                f"# GENERATED from config/telemetry-policy.yaml and {env_name} Helm values.\n"
                "# Review only; the same validated config is embedded in applicationset.yaml.\n"
                + yaml.dump(config, default_flow_style=False, sort_keys=False, width=100)
            )
    staged = []
    try:
        for path, contents in artifacts.items():
            os.makedirs(os.path.dirname(path), exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix=".platform-render-", dir=os.path.dirname(path), text=True)
            with os.fdopen(fd, "w") as f:
                f.write(contents)
            staged.append((temporary, path))
        for temporary, path in staged:
            os.replace(temporary, path)
        if not collector_configs:
            for tier in ("otel-agent", "otel-gateway"):
                obsolete = os.path.join(os.path.dirname(out_file), f"{tier}-config.yaml")
                if os.path.exists(obsolete):
                    os.unlink(obsolete)
    except Exception:
        for temporary, _ in staged:
            if os.path.exists(temporary):
                os.unlink(temporary)
        raise

    print(f"Wrote {out_file} with {len(elements)} Helm entries and {plan_path}.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, TypeError, ValueError, yaml.YAMLError) as exc:
        print(f"ERROR: platform generation failed: {exc}", file=sys.stderr)
        sys.exit(1)
