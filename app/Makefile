# app/Makefile
#
# Build and push aegis-stateful-mock to ECR.
#
# Usage:
#   make build                      # local build only
#   REGISTRY=<acct>.dkr.ecr.eu-central-1.amazonaws.com make push
#   TAG=v0.2 make push              # explicit version tag
#
# After a successful push, the recipe prints the image digest, which the
# operator copies into helm/aegis-statefulset/values.yaml under
# stateful.image.digest. Helm pins on digest, not tag (ADR-039).

.PHONY: build push clean help

REGISTRY ?= TODO_FILL_AWS_ECR_URL
IMAGE     = $(REGISTRY)/aegis-stateful-mock

# TAG defaults to the 7-char git short SHA so a locally-built image is
# always traceable to the commit it was built from — no silent "v0.1"
# collisions across rebuilds. Override with `TAG=v0.2` for a release
# tag. The digest (not the tag) is still what Helm pins on per ADR-039;
# the tag is the human-readable handle.
TAG      ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

help:
	@echo "Targets:"
	@echo "  build  - docker build the image locally"
	@echo "  push   - build, push, and print the digest"
	@echo "  clean  - remove the locally tagged image"

build:
	docker build -t $(IMAGE):$(TAG) -t aegis-stateful-mock:$(TAG) .

push: build
	docker push $(IMAGE):$(TAG)
	@echo "Pushed: $(IMAGE):$(TAG)"
	@DIGEST=$$(aws ecr describe-images --repository-name aegis-stateful-mock --image-ids imageTag=$(TAG) --query 'imageDetails[0].imageDigest' --output text); \
	echo "Digest: $$DIGEST"; \
	echo "Update helm/aegis-statefulset/values.yaml stateful.image.digest with: $$DIGEST"

clean:
	-docker rmi $(IMAGE):$(TAG) aegis-stateful-mock:$(TAG)
