DIR  := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SUDO ?= sudo

.PHONY: setup smoke clean all

setup:
	bash $(DIR)setup.sh

smoke:
	bash $(DIR)smoke/run.sh

clean:
	$(SUDO) pkill -f 'target/release/rusternetes' 2>/dev/null || true
	$(SUDO) podman pod rm -fa 2>/dev/null || true

all: setup smoke
