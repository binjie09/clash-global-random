# clash-global-random

An image wrapper around `metacubex/mihomo` that automatically selects a healthy proxy for the `GLOBAL` selector on startup.

This project uses Mihomo instead of the old Dreamacro Clash image because Mihomo supports newer proxy types such as `vless`.

## What It Does

When the container starts, it:

1. Starts Clash normally
2. Waits for the management API to become ready
3. Reads proxy names from the mounted `config.yaml`
4. Tries proxies in random order
5. Switches `GLOBAL` to a candidate proxy
6. Calls Clash delay test API
7. Stops on the first healthy proxy

If your config defines a Clash `secret`, the startup script reads it automatically and uses it for management API requests.

## Requirements

Your mounted `config.yaml` must include:

- `proxies`
- `external-controller`
- a `GLOBAL` selector, or another selector name passed with `TARGET_GROUP`

Minimal example:

```yaml
port: 7890
mode: Global
external-controller: :9090

proxies:
  - {name: node-a, type: trojan, server: 1.2.3.4, port: 443, password: example}

proxy-groups:
  - name: GLOBAL
    type: select
    proxies:
      - node-a
```

## Quick Start

Pull the published image:

```bash
docker pull ghcr.io/binjie09/clash-global-random:latest
```

Run it directly:

```bash
docker run -d \
  --name clash-global-random \
  -v "$(pwd)/config.yaml:/root/.config/clash/config.yaml:ro" \
  -p 7890:7890 \
  -p 7891:7891 \
  -p 9090:9090 \
  ghcr.io/binjie09/clash-global-random:latest
```

## Docker Compose

Create `config.yaml` in the project root, then run:

```bash
docker-compose up -d
```

The included `docker-compose.yml` pulls `ghcr.io/binjie09/clash-global-random:latest` and mounts `./config.yaml`.

## Local Build

If you want to build locally instead of using GHCR:

```bash
docker build -t clash-global-random:latest .
```

## Environment Variables

- `TARGET_GROUP`: selector to switch, default `GLOBAL`
- `TEST_URL_ENCODED`: encoded URL used by Clash delay API
- `TEST_TIMEOUT_MS`: delay API timeout in milliseconds, default `5000`
- `MAX_DELAY_MS`: optional max acceptable delay, default `0` meaning no upper limit
- `API_HOST`: override management API host, default auto/fallback `127.0.0.1`
- `API_PORT`: override management API port, default parsed from `external-controller` or `9090`
- `API_SECRET`: override Clash secret instead of reading it from config
- `CONFIG_PATH`: config path inside container, default `/root/.config/clash/config.yaml`

## Publish To GHCR

This repo includes a GitHub Actions workflow:

- `.github/workflows/publish.yml`

It also includes a local helper script:

- `scripts/publish-ghcr.sh`

It publishes to:

```text
ghcr.io/binjie09/clash-global-random
```

Before using it:

1. Push this directory as its own GitHub repository
2. Enable GitHub Actions
3. Ensure the repository has package write permission enabled
4. Push to `main` or create a tag like `v1.0.0`

For local publish:

```bash
GHCR_TOKEN=your-token TAG=latest ./scripts/publish-ghcr.sh
```

## Notes

- This image does not modify your Clash config file
- It only switches the selector through Clash management API after startup
- If no healthy proxy is found, Clash still stays running
