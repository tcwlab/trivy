# trivy — Repo context

> **Onboarding handshake:** Read in this order:
>
> 1. `Projects/CLAUDE.md` (global standards, workspace-local)
> 2. `tcwlab/CLAUDE.md` (toolchain context, workspace-local)
> 3. This file (trivy-specific)

---

## What is `trivy`?

`trivy` is the container image that packages Aqua Trivy in a pinned version. It is used in consumer pipelines as a `container:` image for three main use cases:

1. **Image scanning** — scan a freshly built image before pushing to a registry (`trivy image <ref>`).
2. **Filesystem scanning** — scan repository source code for vulnerable dependencies (`trivy fs .`).
3. **Configuration scanning** — scan Helm charts, Kubernetes manifests, and Dockerfiles for misconfigurations (`trivy config <path>`).

The typical CI flow is: build image → scan with Trivy on a staging tag → generate Markdown report and attach to PR description → if clean, promote to production tag.

### Consumers

Like `betterlint`, a universal consumer: all `tcwlab` image repos scan themselves; all consumer verticals (`Atrium/*`, `Spectrum/*`, etc.) scan their service images. IaC repos also use Trivy for config scanning (Helm templates, Tofu modules).

---

## What's inside?

Multi-stage [Dockerfile](https://github.com/tcwlab/trivy/blob/main/Dockerfile):

- **Stage 1 — `base`**: `alpine:3.23` with `curl`, `tar`, `git`, `ca-certificates`. BUILDPLATFORM-aware.
- **Stage 2 — `dependencies`**: architecture detection (`aarch64` → `ARM64`, `x86_64` → `64bit` — Trivy uses its own schema), download Trivy tarball from GitHub, extract to `/usr/local/bin/trivy`, smoke-test `trivy --version`.
- **Stage 3 — `release`**: slim `alpine:3.23` with `ca-certificates` and `git`, non-root user `trivyusr`, workdir `/workspace`, ENTRYPOINT `trivy`.

**No embedded vulnerability database.** The DB is fetched at runtime by Trivy. This keeps the image small and ensures every scan sees current CVE data (a three-week-old DB is not useful).

Platforms: `linux/amd64`, `linux/arm64`.

---

## Tool versioning and pinning strategy

Image tag = Trivy version: `tcwlab/trivy:0.70.0` contains Trivy 0.70.0.

### Update discipline

- **On every Trivy release**: PR with `ARG TRIVY_VERSION=<x.y.z>` (two locations — `dependencies` + `release`).
- **Database updates**: nothing to do; Trivy fetches the DB on demand. The DB index is intentionally not baked into the image.
- **CVE DB strategy**: Trivy team maintains the DB. We rely on Trivy major bumps to maintain compatible DB schemas.

---

## Release procedure

`semantic-release` with Forgejo plugin, auto-tagging, and Docker Hub push like all other image repos. CI pattern from `templates/docker-image-ci.yml`.

---

## What to do when bumping the version

1. PR with `ARG TRIVY_VERSION` (two locations!).
2. Run through CI — smoke test verifies `trivy --version`.
3. **Consumer outreach**: all image repos have a `TRIVY_VERSION:` default in their `ci.yml`. On Trivy major bumps, iterate through the consumer list and coordinate the upgrade (Trivy major releases have sometimes introduced output-format breaking changes that break our PR Markdown generation in image repos).
4. Update `versions.yaml`.

---

## What explicitly does NOT belong in this image

- **Pre-warmed Trivy DB**: no — it goes stale.
- **Trivy server-mode setup**: we do not run a central Trivy server. Each run fetches the DB fresh.
- **Custom policies / severity configuration**: belongs in the consumer repo (`.trivyignore`, `trivy.yaml`). Image stays policy-free.
- **Other scanners** (Grype, Snyk, Anchore): if someone needs Snyk, they build their own image — we commit to Trivy as the single scanner.
- **Other tools** (jq, yq, kubectl): consumers who need Trivy output post-processing do that in their own repo.

---

## Consumer snippets

### Image scan in PR workflow

```yaml
trivy-image:
  name: Trivy Image Scan
  runs-on: ubuntu-22.04
  container:
    image: tcwlab/trivy:0.70.0
  steps:
    - uses: https://data.forgejo.org/actions/checkout@v4
    - name: Scan
      run: |
        trivy image \
          --severity HIGH,CRITICAL \
          --exit-code 1 \
          --format table \
          tcwlab/myservice:${{ github.sha }}
```

### Filesystem scan on source

```yaml
trivy-fs:
  runs-on: ubuntu-22.04
  container:
    image: tcwlab/trivy:0.70.0
  steps:
    - uses: https://data.forgejo.org/actions/checkout@v4
    - run: trivy fs --severity HIGH,CRITICAL --exit-code 1 .
```

### Configuration scan on Helm templates

```yaml
trivy-config:
  runs-on: ubuntu-22.04
  container:
    image: tcwlab/trivy:0.70.0
  steps:
    - uses: https://data.forgejo.org/actions/checkout@v4
    - run: trivy config --severity HIGH,CRITICAL --exit-code 1 ./chart
```

### Markdown report → PR description

Pattern from `templates/docker-image-ci.yml`: run Trivy with `--format template --template '{{ ... }}'`, emit Markdown table, patch PR description via Forgejo API. Idempotent via HTML comment marker. See the template for a full example.

---

## Known pain points / open topics

- **DB download latency**: first invocation in a fresh pipeline downloads the DB — can take 20-40s. Caching the DB across CI runs is possible (`actions/cache` on `~/.cache/trivy`), but we currently don't do it because it's rarely the bottleneck.
- **Severity policy drift**: consumer repos use different severity thresholds (HIGH+CRITICAL vs. CRITICAL only). Long-term convergence on a tcwlab standard policy is needed — currently per-repo.
- **Trivy output stability**: major releases have sometimes introduced JSON schema changes that broke our PR Markdown generation. On Trivy major bump: manually verify PR output in image repos.
- **`--ignore-unfixed` or not**: repos currently mix this. Convergence on a default policy is pending.
