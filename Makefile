# Minikube homelab platform.
#
#   make bootstrap          full install (everything enabled in components.env)
#   make <component>        install one component + its dependencies
#                           (flips the flag in components.env, applies)
#   make hosts              print/append /etc/hosts entries for *.lab.local
#   make status             Applications + pods overview
#   make clean / destroy    teardown (keep / delete the minikube VM)
#
# Per-component targets ensure the base platform (minikube, CRDs, Argo CD)
# exists first, then scripts/enable-component.sh resolves dependencies
# (e.g. `make velero` also enables minio; `make alloy` pulls in
# kube-prometheus-stack, loki-stack, and tempo) and applies once.
.DEFAULT_GOAL := help

HELM_COMPONENTS := cert-manager metallb external-secrets envoy-gateway \
  kube-prometheus-stack loki-stack tempo alloy minio velero kagent agentgateway
SPECIAL_COMPONENTS := olm kubeflow

.PHONY: help bootstrap prereqs cluster crds argocd base apply gateway tunnel hosts \
  update-versions status clean destroy $(HELM_COMPONENTS) $(SPECIAL_COMPONENTS)

help:
	@echo "Targets:"
	@echo "  bootstrap            full platform install (./bootstrap.sh)"
	@echo "  base                 minikube + foundational CRDs + Argo CD only"
	@echo "  apply                rebuild + apply the ApplicationSet as-is"
	@echo "  gateway              (re)apply TLS Gateway + HTTPRoutes"
	@echo "  update-versions      pin every component to its latest release, then apply"
	@echo "  tunnel               minikube tunnel for the homelab profile"
	@echo "  hosts                /etc/hosts entries for *.lab.local"
	@echo "  status | clean | destroy"
	@echo ""
	@echo "Per-component (installs dependencies automatically):"
	@echo "  $(HELM_COMPONENTS) $(SPECIAL_COMPONENTS)"

bootstrap:
	./bootstrap.sh

# Refreshes versions.env to the latest non-prerelease version of every
# component (queries the official Helm repos / GitHub releases), then
# rebuilds + applies so Argo CD rolls the upgrades out.
update-versions: base
	./update-versions.sh
	bash scripts/04-apply-apps.sh

prereqs:
	bash scripts/00-prereqs.sh

cluster: prereqs
	bash scripts/01-minikube.sh

crds: cluster
	bash scripts/02-foundational-crds.sh

argocd: crds
	bash scripts/03-argocd.sh

base: argocd

apply: base
	bash scripts/04-apply-apps.sh

gateway: base
	bash scripts/08-platform-gateway.sh

$(HELM_COMPONENTS): base
	bash scripts/enable-component.sh $@

$(SPECIAL_COMPONENTS): base
	bash scripts/enable-component.sh $@

# minikube commands default to the "minikube" profile; this cluster is "homelab".
tunnel:
	minikube tunnel -p $${MINIKUBE_PROFILE:-homelab}

hosts:
	@GATEWAY_IP=$$(kubectl -n envoy-gateway-system get gateway platform -o jsonpath='{.status.addresses[0].value}' 2>/dev/null); \
	if [ -z "$$GATEWAY_IP" ]; then \
	  echo "Gateway has no address yet. With the docker driver, run 'minikube tunnel' first."; exit 1; \
	fi; \
	echo "$$GATEWAY_IP argocd.lab.local grafana.lab.local prometheus.lab.local minio.lab.local tempo.lab.local"; \
	echo ""; \
	echo "Append it with:"; \
	echo "  make hosts | head -1 | sudo tee -a /etc/hosts"

status:
	kubectl get applications -n argocd
	kubectl get pods -A

clean:
	./cleanup.sh --keep-minikube

destroy:
	./cleanup.sh
