# =============================================================================
# All-Rust Kubernetes stack:
#   Rusternetes CRI kubelet -> containerd-rs -> crun  +  flannel-rs  +  rusternetes-dns
#
# Thin wrappers over the committed scripts (setup.sh / smoke/run.sh /
# conformance/run.sh). The scripts hold all the real logic; this is just the
# turnkey entrypoint.
#
#   make setup        build containerd-rs + kubelet + the baked node image
#   make smoke        stand the stack up (project crs-cdrs-flannel) + assert (7/7)
#   make conformance  one upstream [NodeConformance] ginkgo spec, green
#   make clean        scoped teardown of project crs-cdrs-flannel ONLY (down -v)
#   make all          setup + smoke
# =============================================================================
DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

.PHONY: setup smoke conformance clean all

setup:
	bash $(DIR)setup.sh

smoke:
	bash $(DIR)smoke/run.sh

conformance:
	bash $(DIR)conformance/run.sh

# Project-scoped teardown ONLY. Never a broad `docker rm`/grep sweep and never a
# mutation of the shared $RSRC tree. Mirrors the smoke harness's COMPOSE array
# (base compose.flannel.yml from the rusternetes CRI worktree + this stack's
# override) so `down -v` targets exactly project crs-cdrs-flannel.
clean:
	@RSRC="$$( [ -f $(DIR).rusternetes-src-path ] && cat $(DIR).rusternetes-src-path || echo $(DIR).rusternetes-cri )"; \
	if [ ! -d "$$RSRC" ]; then \
	  echo "rusternetes worktree not found at $$RSRC — nothing to tear down"; exit 0; \
	fi; \
	export STACK_DIR="$(DIR)"; \
	export CERTS_PATH="$(DIR).crs-cdrs-flannel/certs"; \
	export KUBELET_VOLUMES_PATH="$(DIR).crs-cdrs-flannel/volumes"; \
	export EMPTY_MANIFESTS="$(DIR).crs-cdrs-flannel/manifests-empty"; \
	docker compose -p crs-cdrs-flannel \
	  -f "$$RSRC/compose.flannel.yml" \
	  -f "$(DIR)compose.flannel.containerdrs.yml" \
	  down -v --remove-orphans

all: setup smoke
