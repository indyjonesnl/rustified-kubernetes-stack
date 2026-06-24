DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PROJECT := k0s-rhino-crunfl

.PHONY: smoke conformance conformance-sigs clean all up down

up:
	docker compose -p $(PROJECT) -f $(DIR)docker-compose.yml up -d --build

down:
	docker compose -p $(PROJECT) -f $(DIR)docker-compose.yml down -v

smoke:
	bash $(DIR)smoke/run.sh

# Upstream Kubernetes conformance against the rhino-backed cluster.
# Default FOCUS = sig-api-machinery configmap Watchers (etcd's core responsibility).
# Override via env, e.g.: FOCUS='\[NodeConformance\]' make -C stacks/k0s-rhino-crun-flannelrs conformance
conformance:
	bash $(DIR)conformance/run.sh

# Per-SIG [Conformance] subsets (one focus per sig, own JUnit + gate). Brings the
# cluster up once and loops: api-machinery apps auth autoscaling network node scheduling.
# Subset via SIGS, e.g.: SIGS='node network' make -C stacks/k0s-rhino-crun-flannelrs conformance-sigs
conformance-sigs:
	bash $(DIR)conformance/run-sigs.sh

clean: down

all: up smoke
