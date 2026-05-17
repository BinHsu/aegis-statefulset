# Makefile — repo-level developer entrypoint.
#
# Mirrors the CI gates in .github/workflows/pr-validation.yml so that
# "passes locally" predicts "passes CI". Two aggregate targets back the
# two git hooks in scripts/git-hooks/:
#
#   make precommit  -> fast gate   (anonymisation + secrets + kubeconform)
#   make prepush    -> full gate   (precommit + Go app + helm + terraform)
#
# Install the hooks once per clone:
#
#   make hooks-install
#
# Tool-dependent targets (helm-lint, tf-fmt, go-lint) skip cleanly when
# the tool is absent — the same posture as the kubeconform check in the
# pre-commit hook. The deterministic Go checks (gofmt/vet/test/build)
# require Go and fail hard if it is missing.

APP_DIR := $(CURDIR)/app

.PHONY: help hooks-install precommit prepush anon \
        go-fmt go-vet go-test go-build go-vuln go-lint \
        helm-lint tf-fmt clean

help:
	@echo "Targets:"
	@echo "  hooks-install  - point git core.hooksPath at scripts/git-hooks/"
	@echo "  precommit      - fast gate: anonymisation + secrets + kubeconform"
	@echo "  prepush        - full gate: precommit + Go app + helm + terraform"
	@echo "  go-fmt/go-vet/go-test/go-build/go-vuln/go-lint - individual Go checks"
	@echo "  helm-lint/tf-fmt - individual infra checks"

# hooks-install — activate the committed hooks for this clone. core.hooksPath
# picks up every hook in scripts/git-hooks/ (pre-commit + pre-push), so a new
# hook needs no per-developer re-install. Idempotent.
hooks-install:
	git config core.hooksPath scripts/git-hooks
	chmod +x scripts/git-hooks/*
	@echo "git hooks active: core.hooksPath -> scripts/git-hooks"

# anon — anonymisation + stale-content + credential + hallucination gate.
# Reuses the pre-commit hook in whole-repo mode (--all), so the Makefile
# never duplicates the scan logic.
anon:
	./scripts/git-hooks/pre-commit --all

# --- Go application checks (app/) --------------------------------------
go-fmt:
	@unformatted=$$(cd $(APP_DIR) && gofmt -l .); \
	  if [ -n "$$unformatted" ]; then \
	    echo "FAIL gofmt — run 'gofmt -w app/' on:"; echo "$$unformatted"; \
	    exit 1; \
	  fi
	@echo "OK: gofmt clean."

go-vet:
	cd $(APP_DIR) && go vet ./...

go-test:
	cd $(APP_DIR) && go test ./... -race -count=1

go-build:
	cd $(APP_DIR) && go build ./...

# go-vuln — govulncheck mirrors the CI Go gate. Run via `go run` so no
# global install is needed; the version resolves at run time.
go-vuln:
	cd $(APP_DIR) && go run golang.org/x/vuln/cmd/govulncheck@latest ./...

# go-lint — golangci-lint runs locally only (not in CI: its ruleset
# shifts between releases and would turn CI red on a tooling bump rather
# than a code change). Skips cleanly when not installed.
go-lint:
	@if command -v golangci-lint >/dev/null 2>&1; then \
	  cd $(APP_DIR) && golangci-lint run ./...; \
	else \
	  echo "skipped — golangci-lint not in PATH (brew install golangci-lint)"; \
	fi

# --- Infra checks ------------------------------------------------------
helm-lint:
	@if command -v helm >/dev/null 2>&1; then \
	  helm lint helm/aegis-statefulset/; \
	else \
	  echo "skipped — helm not in PATH"; \
	fi

tf-fmt:
	@if command -v terraform >/dev/null 2>&1; then \
	  terraform -chdir=infrastructure/terraform fmt -check -recursive; \
	else \
	  echo "skipped — terraform not in PATH"; \
	fi

# --- Aggregate gates (back the git hooks) ------------------------------
precommit: anon

prepush: anon go-fmt go-vet go-test go-build go-vuln go-lint helm-lint tf-fmt
	@echo "prepush gate clean — safe to push"

clean:
	cd $(APP_DIR) && go clean
