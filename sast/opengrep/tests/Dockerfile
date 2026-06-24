# syntax=docker/dockerfile:1
#
# Hardened, multi-stage image that reproduces the GitHub Actions rule-test
# environment locally with zero host install. The opengrep binary is
# cosign-verified (the same Sigstore provenance check ../action.yml performs) in
# a throwaway builder stage; the final image is minimal, runs as a non-root
# user, and contains only the verified binary plus Python (for run.py).
#
#   # 1:1 with the GitHub-hosted runner (amd64); emulated on Apple Silicon
#   docker build --platform linux/amd64 -t opengrep-rules sast/opengrep/tests
#   docker run  --rm --platform linux/amd64 -v "$PWD:/work" opengrep-rules
#   docker run  --rm --platform linux/amd64 -v "$PWD:/work" opengrep-rules \
#       opengrep scan --no-rewrite-rule-ids --config sast/opengrep/rules/ .
#
#   # fast native build on Apple Silicon (TARGETARCH picks the arm64 binary)
#   docker build -t opengrep-rules sast/opengrep/tests
#   docker run --rm -v "$PWD:/work" opengrep-rules

# Pinned base: python:3.12-slim multi-arch manifest digest.
FROM python:3.12-slim@sha256:090ba77e2958f6af52a5341f788b50b032dd4ca28377d2893dcf1ecbdfdfe203 AS builder

# Keep OPENGREP_VERSION in sync with ../action.yml and
# ../../../.github/workflows/test-opengrep-rules.yml.
ARG OPENGREP_VERSION=v1.21.0
ARG COSIGN_VERSION=v3.0.6
# TARGETARCH (amd64 | arm64) is supplied automatically by BuildKit from the
# build/run --platform, so one Dockerfile serves both architectures.
ARG TARGETARCH

# Everything below runs in the throwaway `builder` stage — curl, cosign, and the
# apt layers never reach the final image. `set -e` makes any failed step (e.g.
# a failed signature check) abort the build.
RUN set -eux; \
    # download tooling only; --no-install-recommends + dropping the apt lists
    # keeps the (discarded) builder layer small.
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    # map the build arch to the matching release asset / cosign binary.
    case "$TARGETARCH" in \
      amd64) asset=opengrep_manylinux_x86;     cosign_arch=amd64 ;; \
      arm64) asset=opengrep_manylinux_aarch64; cosign_arch=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    # fetch the opengrep binary together with its Sigstore signature + cert,
    # plus the cosign CLI used to check them.
    rel="https://github.com/opengrep/opengrep/releases/download/${OPENGREP_VERSION}"; \
    curl -fsSL "${rel}/${asset}"      -o /tmp/opengrep; \
    curl -fsSL "${rel}/${asset}.sig"  -o /tmp/opengrep.sig; \
    curl -fsSL "${rel}/${asset}.cert" -o /tmp/opengrep.cert; \
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${cosign_arch}" \
      -o /usr/local/bin/cosign; \
    chmod +x /usr/local/bin/cosign; \
    # verify provenance: the binary must be signed by opengrep's GitHub Actions
    # OIDC identity (same check as ../action.yml). Fails the build if it isn't.
    cosign verify-blob \
      --certificate /tmp/opengrep.cert \
      --signature /tmp/opengrep.sig \
      --certificate-identity-regexp "https://github.com/opengrep/opengrep/" \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
      /tmp/opengrep; \
    # smoke-test: also catches an arch mismatch (wrong-arch binary won't exec).
    chmod 0755 /tmp/opengrep; \
    /tmp/opengrep --version

# ---- final: minimal runtime, non-root, only the verified binary ----
FROM python:3.12-slim@sha256:090ba77e2958f6af52a5341f788b50b032dd4ca28377d2893dcf1ecbdfdfe203

COPY --from=builder /tmp/opengrep /usr/local/bin/opengrep

# Run as a non-root, no-login user. The high fixed UID avoids colliding with
# host UIDs on the bind-mounted workspace.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin runner
USER 10001
WORKDIR /work
# OPENGREP_TEST_BIN makes run.py prefer opengrep; PYTHONDONTWRITEBYTECODE avoids
# scattering .pyc files into the mounted repo.
ENV OPENGREP_TEST_BIN=opengrep \
    PYTHONDONTWRITEBYTECODE=1
# The repo is mounted at /work at runtime; override the command to scan instead.
CMD ["python3", "sast/opengrep/tests/run.py"]
