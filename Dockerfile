# ─────────────────────────────────────────────────────────────────────────────
# tcwlab/trivy
#
# Minimal Alpine image with pinned Trivy version.
# Image tag matches Trivy version: tcwlab/trivy:0.70.0
#
# Supported platforms: linux/amd64, linux/arm64
#
# Build (multi-arch):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     --build-arg TRIVY_VERSION=0.70.0 \
#     -t tcwlab/trivy:0.70.0 --push .
# ─────────────────────────────────────────────────────────────────────────────

#####
# STEP 1: base image
#####
FROM --platform=$BUILDPLATFORM alpine:3.23 AS base
ARG BUILDPLATFORM
# hadolint ignore=DL3018
RUN apk add -U --no-cache curl tar git ca-certificates && \
    apk upgrade && \
    rm -rf /var/cache/apk/*

#####
# STEP 2: download trivy binary (arch-aware)
#####
FROM base AS dependencies
ARG TRIVY_VERSION=0.70.0
SHELL ["/bin/sh", "-c"]
RUN case "$(apk --print-arch)" in \
        aarch64) LOCAL_ARCH="ARM64" ;; \
        x86_64)  LOCAL_ARCH="64bit" ;; \
        *) echo "Unsupported architecture: $(apk --print-arch)" && exit 1 ;; \
    esac && \
    curl -fsSL \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${LOCAL_ARCH}.tar.gz" \
      -o /tmp/trivy.tar.gz && \
    tar xzf /tmp/trivy.tar.gz -C /usr/local/bin/ trivy && \
    rm /tmp/trivy.tar.gz && \
    chmod +x /usr/local/bin/trivy && \
    trivy --version

#####
# STEP 3: production image
#####
FROM alpine:3.23 AS release
ARG TRIVY_VERSION=0.70.0

LABEL org.opencontainers.image.title="trivy" \
      org.opencontainers.image.description="trivy — pinned version for reproducible CI scanning" \
      org.opencontainers.image.vendor="The Chameleon Way" \
      org.opencontainers.image.url="https://hub.docker.com/r/tcwlab/trivy" \
      org.opencontainers.image.source="https://github.com/tcwlab/trivy" \
      org.opencontainers.image.version="${TRIVY_VERSION}"

# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates git && \
    apk upgrade --no-cache && \
    addgroup -S trivyusr && \
    adduser -S trivyusr -G trivyusr

COPY --from=dependencies /usr/local/bin/trivy /usr/local/bin/trivy

USER trivyusr
WORKDIR /workspace
ENTRYPOINT ["trivy"]
