DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: smoke clean all

smoke:
	bash $(DIR)smoke/run.sh

clean:
	minikube delete -p k8s-cridockerd 2>/dev/null || true

all: smoke
