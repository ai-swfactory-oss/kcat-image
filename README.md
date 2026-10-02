# kcat-image

Minimal, self-updating container image with [kcat](https://github.com/edenhill/kcat), the Kafka producer/consumer CLI.

```
ghcr.io/ai-swfactory/kcat:latest
ghcr.io/ai-swfactory/kcat:1.7.1            # kcat version, moves with rebuilds
ghcr.io/ai-swfactory/kcat:1.7.1-YYYYMMDD   # immutable per published build
```

Platforms: `linux/amd64`, `linux/arm64`.

## What is in the image

One layer, about 4.5 MB compressed:

- `/bin/kcat`: statically linked against musl, stripped, no `/nix/store` references.
- `/etc/ssl/certs/ca-bundle.crt`: CA certificates for TLS brokers.

No shell, no package manager, runs as `65534:65534` (nobody).

Built without Avro/Schema Registry and without SASL/OIDC: plaintext and TLS brokers only. This keeps the binary small and the build robust.

## Usage

```sh
# produce one message
echo "hello" | docker run --rm -i ghcr.io/ai-swfactory/kcat -b kafka:9092 -t my-topic -P

# consume one message and exit
docker run --rm ghcr.io/ai-swfactory/kcat -b kafka:9092 -t my-topic -C -c 1 -e
```

Kubernetes CronJob publishing a tick (the image has no shell, so the message comes from a mounted file; kcat sends each file as one message):

```yaml
containers:
  - name: tick
    image: ghcr.io/ai-swfactory/kcat:1.7.1-YYYYMMDD
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
| `update` | Daily 04:17 UTC | Moves `nixpkgs` to the latest `nixos-unstable` channel and commits `flake.lock`. If the image's Nix store path changed, builds, tests and publishes a new image. Otherwise publishes nothing. |
| `build` | Push to `main` touching the flake or the workflow, manual | Builds natively on amd64 and arm64, smoke-tests against a real broker (Redpanda), publishes the multi-arch image. |
| `pr` | Every pull request | Builds and smoke-tests without publishing. Dependabot PRs (GitHub Actions versions, weekly) are merged automatically when green. |

The daily lock commit also keeps the repository active, so GitHub never disables the schedule. A failing run publishes nothing (the previous image stays) and GitHub emails the failure.

The build is reproducible: same `flake.lock`, same image digest.

## Local build

```sh
nix build .#image && docker load < result
```

## License

The build code in this repository is MIT. kcat itself is BSD-2-Clause (https://github.com/edenhill/kcat).
