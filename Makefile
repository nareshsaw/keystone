SHELL := /bin/bash
REVISION ?= main

.PHONY: up cluster app bootstrap wait verify down slo finops

up: cluster app bootstrap wait verify   ## Create everything from scratch on a local kind cluster

cluster:                                ## Create the 4-node kind cluster
	kind create cluster --config kind/cluster.yaml

app:                                    ## Build the sample app and load it into kind
	docker build -t keystone/orders:dev apps/orders
	kind load docker-image keystone/orders:dev --name keystone

bootstrap:                              ## Install Argo CD and hand over to GitOps
	scripts/bootstrap.sh $(REVISION)

wait:                                   ## Wait for all Argo CD apps to be Synced + Healthy
	scripts/wait-for-apps.sh

verify:                                 ## Run the platform acceptance checks
	scripts/verify-platform.sh

down:                                   ## Delete the kind cluster
	kind delete cluster --name keystone

slo:                                    ## Regenerate Prometheus SLO rules from slos/*.yaml (needs sloth)
	sloth generate -i slos/orders.yaml -o gitops/platform/observability-config/slo-orders.yaml

finops:                                 ## Run the FinOps advisor against the local cluster (report only)
	scripts/finops-advisor.sh check
