DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SUDO ?= sudo

.PHONY: setup smoke clean all

setup:
	$(SUDO) bash $(DIR)setup.sh

smoke:
	$(SUDO) YOUKI=/usr/local/bin/youki bash $(DIR)smoke/smoke-test.sh

clean:
	$(SUDO) podman pod rm -f py-smoke 2>/dev/null || true
	$(SUDO) podman rm -f py-exec py-logs py-rt 2>/dev/null || true

all: setup smoke
