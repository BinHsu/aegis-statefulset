# app/Dockerfile
#
# Two-stage build for aegis-stateful-mock.
#   Stage 1: golang:1.22-alpine — produces a statically-linked binary.
#   Stage 2: distroless static  — runtime image with no shell, no package
#                                 manager, non-root UID, ~2 MB on disk.
#
# SHA pinning discipline (ADR-039): the runtime base image is pinned to a
# digest. The build base is left tag-pinned (golang:1.22-alpine) for
# easier weekly Go patch refreshes via Renovate; the build artefact is
# the binary, not the build image.
#
# TODO_VERIFY_FROM_DOCKER_HUB: replace the placeholder digest below with
# the current digest of `gcr.io/distroless/static:nonroot` before the
# first push. Get it via:
#   docker pull gcr.io/distroless/static:nonroot
#   docker inspect gcr.io/distroless/static:nonroot \
#     --format='{{index .RepoDigests 0}}'

# --- Build stage --------------------------------------------------------
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY main.go .
# CGO_ENABLED=0 ensures static binary (required for distroless/static base).
# -ldflags="-s -w" strips debug + symbol tables.
RUN CGO_ENABLED=0 GOOS=linux go build -o /app -ldflags="-s -w" main.go

# --- Runtime stage ------------------------------------------------------
FROM gcr.io/distroless/static@sha256:e3f945647ffb95b5839c07038d64f9811adf17308b9121d8a2b87b6a22a80a39
COPY --from=build /app /app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app"]
