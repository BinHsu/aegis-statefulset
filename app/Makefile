# app/Makefile
#
# Build and push aegis-stateful-mock to ECR.
#
# Usage:
#   make build                      # local build only
#   REGISTRY=<acct>.dkr.ecr.eu-central-1.amazonaws.com make push
#   TAG=v0.2 make push              # version bump
#
# After a successful push, the recipe prints the image digest, which the
# operator copies into helm/aegis-statefulset/values.yaml under
# stateful.image.digest. Helm pins on digest, not tag (ADR-039).

.PHONY: build push clean help

REGISTRY ?= TODO_FILL_AWS_ECR_URL
IMAGE     = $(REGISTRY)/aegis-stateful-mock
TAG      ?= v0.1

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
