# kcat-image

[![update](https://github.com/ai-swfactory-oss/kcat-image/actions/workflows/update.yml/badge.svg)](https://github.com/ai-swfactory-oss/kcat-image/actions/workflows/update.yml)
[![build](https://github.com/ai-swfactory-oss/kcat-image/actions/workflows/build.yml/badge.svg)](https://github.com/ai-swfactory-oss/kcat-image/actions/workflows/build.yml)

Minimal, self-updating container image with [kcat](https://github.com/edenhill/kcat), the Kafka producer/consumer CLI.

```
ghcr.io/ai-swfactory-oss/kcat:latest
ghcr.io/ai-swfactory-oss/kcat:1.7.1            # kcat version, moves with rebuilds
ghcr.io/ai-swfactory-oss/kcat:1.7.1-YYYYMMDD   # per published build
ghcr.io/ai-swfactory-oss/kcat:nix-<key>        # content-addressed: one tag per exact image
```

Platforms: `linux/amd64`, `linux/arm64`.

## What is in the image

One layer, about 4.5 MB compressed:

- `/bin/kcat`: statically linked against musl, stripped, no `/nix/store` references.
- `/etc/ssl/certs/ca-bundle.crt`: CA certificates for TLS brokers.
- `/usr/share/licenses/`: the license texts of everything above.

No shell, no package manager, runs as `65534:65534` (nobody).

Built without Avro/Schema Registry and without SASL/OIDC: plaintext and TLS brokers only. This keeps the binary small and the build robust.

## Usage

```sh
# produce one message
echo "hello" | docker run --rm -i ghcr.io/ai-swfactory-oss/kcat -b kafka:9092 -t my-topic -P

# consume one message and exit
docker run --rm ghcr.io/ai-swfactory-oss/kcat -b kafka:9092 -t my-topic -C -c 1 -e
```

Kubernetes CronJob publishing a tick (the image has no shell, so the message comes from a mounted file; kcat sends each file as one message):

```yaml
containers:
  - name: tick
    image: ghcr.io/ai-swfactory-oss/kcat:1.7.1-YYYYMMDD
    args: ["-b", "kafka-bootstrap:9092", "-t", "jobs.tick", "-k", "pool-sync", "-P", "/tick/message.json"]
    volumeMounts:
      - { name: tick, mountPath: /tick, readOnly: true }
    resources:
      requests: { cpu: 10m, memory: 16Mi }
volumes:
  - name: tick
    configMap: { name: pool-sync-tick }
```

## How it stays up to date (no maintenance)

| Workflow | When | What |
|---|---|---|
| `update` | Daily 04:17 UTC | Moves `nixpkgs` to the latest `nixos-unstable` channel and commits `flake.lock`. Then checks whether the image for that lock is already published (tag `nix-<key>`, derived from the image's Nix store paths). If not, builds, tests and publishes it. A failed build is retried the next day. |
| `build` | Push to `main` touching the flake or the workflow, manual, called by `update` | Builds natively on amd64 and arm64, smoke-tests against a real broker (Redpanda), publishes the multi-arch image. |
| `pr` | Every pull request | Builds and smoke-tests without publishing. |
| `failures` | After every `update` or `build` run on `main` | A failure opens one issue labelled `build-failure` (or comments on the open one); the next successful run closes it. |

The daily lock commit also keeps the repository active, so GitHub never disables the schedule. A failing run publishes nothing: the previous image keeps being served.

GitHub Actions are referenced by major tag (`@v7`, `@v31`), so minor and patch releases apply automatically. A new major is only needed when GitHub retires an old Node runtime; if that ever breaks the build, the `failures` issue says so.

The build is reproducible: same `flake.lock`, same image.

## Local build

```sh
nix build .#image && docker load < result
```

## License

The build code in this repository is BSD-2-Clause, the same license as [kcat](https://github.com/edenhill/kcat).

The image redistributes kcat and the libraries statically linked into it, each under its own license. Their license texts ship in the image under `/usr/share/licenses/<component>/`:

| Component | License |
|---|---|
| kcat | BSD-2-Clause |
| librdkafka | BSD-2-Clause; its bundled code adds MIT, Zlib, BSD-3-Clause, Apache-2.0, ISC and public domain (`LICENSES.txt`) |
| OpenSSL | Apache-2.0 |
| zstd | BSD-3-Clause (dual-licensed upstream; used under BSD) |
| zlib | Zlib |
| yajl | ISC |
| musl | MIT |
| CA bundle (Mozilla NSS `certdata.txt`) | MPL-2.0 |

The `org.opencontainers.image.licenses` label carries the combined SPDX expression.
