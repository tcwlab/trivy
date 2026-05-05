# tcwlab/trivy

> Pinned [Aqua Trivy](https://aquasecurity.github.io/trivy/) security scanner in a minimal Alpine container. Part of the [tcwlab](https://github.com/tcwlab) open-source CI/CD toolchain.

[![Docker Pulls](https://img.shields.io/docker/pulls/tcwlab/trivy?label=pulls)](https://hub.docker.com/r/tcwlab/trivy)
[![Image Size](https://img.shields.io/docker/image-size/tcwlab/trivy/latest?label=size)](https://hub.docker.com/r/tcwlab/trivy/tags)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

---

## Quick start

```bash
docker pull tcwlab/trivy:latest

# Run a container image scan
docker run --rm tcwlab/trivy:latest image alpine:3.23
```

Or in a Forgejo / GitHub Actions container job:

```yaml
scan:
  runs-on: ubuntu-22.04
  container:
    image: tcwlab/trivy:latest
  steps:
    - uses: https://data.forgejo.org/actions/checkout@v4
    - run: trivy config --severity HIGH,CRITICAL --exit-code 1 .
```

> Quick-start examples use `:latest` so you can try the image immediately. For
> production CI pipelines, pin a concrete tag — see [Tags](#tags) below.

---

## Tags

> Version numbers below are illustrative. For the current set of tags, see
> [Docker Hub tags](https://hub.docker.com/r/tcwlab/trivy/tags).

| Tag | Description |
|-----|-------------|
| `0.70.0`, `latest` | Trivy 0.70.0 (current) |

**Always pin a concrete version in production.** The image tag is the Trivy version number — `tcwlab/trivy:0.70.0` contains exactly Trivy 0.70.0. `latest` is a rolling reference; pinning protects your pipeline from a scanner upgrade that lands without a PR.

---

## Supported architectures

- `linux/amd64`
- `linux/arm64`

Every tag is a multi-arch manifest list. Docker automatically pulls the right architecture.

---

## What's included

| Component | Version | Purpose |
|-----------|---------|---------|
| [`trivy`](https://github.com/aquasecurity/trivy) | `0.70.0` | Multi-scanner for vulnerabilities, misconfigurations, secrets, and SBOM |
| Base image | `alpine:3.23` | Slim + hardened Linux foundation |
| Non-root user | `trivyusr` | Container runs as non-root for security |
| CA certificates | `git`, `ca-certificates` | For HTTPS and Git operations |

**No embedded vulnerability database.** Trivy automatically fetches and caches the latest vulnerability DB at scan runtime. This keeps the image small and ensures every scan sees up-to-date CVE data.

---

## Usage

### Scan a container image (from registry)

```bash
docker run --rm tcwlab/trivy:0.70.0 image \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  alpine:3.23
```

### Scan filesystem for vulnerable dependencies

```bash
docker run --rm -v "$PWD:/workspace" tcwlab/trivy:0.70.0 fs \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  /workspace
```

### Scan configuration files (Helm, Kubernetes, Docker, Terraform)

```bash
docker run --rm -v "$PWD:/workspace" tcwlab/trivy:0.70.0 config \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  /workspace/helm-chart
```

### Forgejo / GitHub Actions examples

**Image scan in CI:**

```yaml
trivy-image:
  name: Scan Container Image
  runs-on: ubuntu-22.04
  container:
    image: tcwlab/trivy:0.70.0
  steps:
    - name: Scan built image
      run: |
        trivy image \
          --severity HIGH,CRITICAL \
          --exit-code 1 \
          --ignore-unfixed \
          tcwlab/myservice:${{ github.sha }}
```

**Filesystem scan in CI:**

```yaml
trivy-fs:
  name: Scan Dependencies
  runs-on: ubuntu-22.04
  container:
    image: tcwlab/trivy:0.70.0
  steps:
    - uses: https://data.forgejo.org/actions/checkout@v4
    - name: Scan repository
      run: |
        trivy fs \
          --severity HIGH,CRITICAL \
          --exit-code 1 \
          --ignore-unfixed \
          .
```

**Config scan in CI:**

```yaml
trivy-config:
  name: Scan Configurations
  runs-on: ubuntu-22.04
  container:
    image: tcwlab/trivy:0.70.0
  steps:
    - uses: https://data.forgejo.org/actions/checkout@v4
    - name: Scan Helm charts and manifests
      run: |
        trivy config \
          --severity HIGH,CRITICAL \
          --exit-code 1 \
          ./chart
```

### Common options

| Flag | Purpose |
|------|---------|
| `--severity CRITICAL,HIGH` | Filter results by severity (default: all) |
| `--exit-code 1` | Exit non-zero if vulnerabilities are found |
| `--ignore-unfixed` | Skip vulnerabilities without a fix available |
| `--format json` | Emit structured JSON (good for post-processing) |
| `--format table` | Human-readable table (default) |
| `--format template` | Custom template output (for Markdown reports) |

Full CLI documentation: [Trivy CLI Reference](https://aquasecurity.github.io/trivy/latest/docs/references/cli/)

---

## Configuration

### Environment variables for private registries

If you need to scan images from private Docker registries, set:

```bash
docker run --rm \
  -e TRIVY_USERNAME=<username> \
  -e TRIVY_PASSWORD=<password> \
  tcwlab/trivy:0.70.0 image <private-image:tag>
```

Other supported env vars:

| Variable | Purpose |
|----------|---------|
| `TRIVY_USERNAME` | Registry username (basic auth) |
| `TRIVY_PASSWORD` | Registry password or token |
| `TRIVY_DB_REPOSITORY` | Custom Trivy DB mirror (default: GitHub) |
| `TRIVY_JAVA_DB_REPOSITORY` | Custom Java DB mirror (if scanning Java) |

### Volume mount points

| Path | Purpose |
|------|---------|
| `/workspace` | Default working directory for scans |
| `$HOME/.cache/trivy` | Trivy DB cache (persists between runs for speed) |

To cache the vulnerability DB across CI runs (saves ~20-40s on first scan):

```yaml
- uses: https://data.forgejo.org/actions/cache@v4
  with:
    path: ~/.cache/trivy
    key: trivy-db-${{ runner.os }}
```

---

## Version strategy

The image tag mirrors the Trivy version. When Aqua Security releases Trivy `x.y.z`, we build and publish `tcwlab/trivy:x.y.z`. Pinning is straightforward:

- **Production:** Pin the exact version (e.g., `0.70.0`)
- **Local testing:** Use `latest` if you want the newest

Trivy major releases sometimes introduce breaking changes in scan output formats. If you have custom parsing (e.g., in a Markdown report template), verify your post-processing after a Trivy major bump.

Current pinned version: see `tcwlab/versions.yaml` for the snapshot across all tcwlab images.

---

## Source, issues, contributing

- **Source**: [`github.com/tcwlab/trivy`](https://github.com/tcwlab/trivy)
- **Issues / feature requests**: [`github.com/tcwlab/trivy/issues`](https://github.com/tcwlab/trivy/issues)
- **Docker Hub**: [`hub.docker.com/r/tcwlab/trivy`](https://hub.docker.com/r/tcwlab/trivy)

---

## Build, supply chain

Every release is built and published by the repo's own [`.forgejo/workflows/ci.yml`](https://github.com/tcwlab/trivy/blob/main/.forgejo/workflows/ci.yml) on a Forgejo runner:

- **Multi-arch build** (`linux/amd64`, `linux/arm64`) via `docker buildx` with `--sbom=true --provenance=mode=max`
- **Lint** via `betterlint` against Dockerfile and scripts
- **Smoke test** to verify `trivy --version` works
- **Security scan** of the built image itself using Trivy (recursive — we scan with the tool we're shipping)
- **Push to Docker Hub** on version tags, with semantic versioning

---

## License

Apache License 2.0. See [`LICENSE`](LICENSE) for the full text. Trivy itself is also Apache-2.0 licensed; see [aquasecurity/trivy](https://github.com/aquasecurity/trivy).
