IMAGE   ?= kind-node-crun:dev
CLUSTER ?= crun
DIR     := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: image up smoke conformance down clean all

image:
	docker build -f $(DIR)node.Dockerfile -t $(IMAGE) $(DIR)

up:
	kind delete cluster --name $(CLUSTER) 2>/dev/null || true
	kind create cluster --image $(IMAGE) --config $(DIR)kind-config.yaml --wait 120s
	kubectl -n kube-system wait --for=condition=Ready pod --all --timeout=120s

smoke:
	bash $(DIR)smoke/smoke-test.sh

# sig-network [Conformance] via Sonobuoy (creates its own cluster + tears down). Heavy.
conformance:
	bash $(DIR)conformance/run.sh

down:
	kind delete cluster --name $(CLUSTER) 2>/dev/null || true

clean: down
	docker rmi $(IMAGE) 2>/dev/null || true

all: image up smoke down
