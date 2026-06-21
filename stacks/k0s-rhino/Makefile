DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PROJECT := k0s-rhino

.PHONY: smoke conformance clean all up down

up:
	docker compose -p $(PROJECT) -f $(DIR)docker-compose.yml up -d --build

down:
	docker compose -p $(PROJECT) -f $(DIR)docker-compose.yml down -v

smoke:
	bash $(DIR)smoke/run.sh

# Upstream Kubernetes conformance against the rhino-backed cluster.
# Default FOCUS = sig-api-machinery configmap Watchers (etcd's core responsibility).
# Override via env, e.g.: FOCUS='\[NodeConformance\]' make -C stacks/k0s-rhino conformance
conformance:
	bash $(DIR)conformance/run.sh

clean: down

all: up smoke
