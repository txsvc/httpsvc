# Design Document: Multi-Site Reverse Proxy

## Overview

httpsvc is a containerised Caddy wrapper that serves multiple domains from a
single instance. The implementation is configuration-driven — no custom Go
modules are needed. The work consists of: (1) a main Caddyfile that imports
per-site snippets, (2) example site snippets, (3) an entrypoint script with a
config-change polling loop, (4) updated Containerfile and Makefile.

## Architecture

```mermaid
flowchart TD
    subgraph Container
        EP[deploy/run<br/>entrypoint script]
        C[Caddy process<br/>httpsvc]
        A[Admin API<br/>localhost:2019]
        CF[/etc/caddy/Caddyfile/]
        SS[/etc/caddy/sites/*.caddy/]
    end

    subgraph Volumes
        DATA[/data<br/>certs & ACME state]
        SITES[/sites<br/>logs & static files]
        CONF[/etc/caddy/sites<br/>site configs]
    end

    EP -->|starts| C
    EP -->|polls & reloads| A
    C -->|reads| CF
    CF -->|imports| SS
    C -->|stores certs| DATA
    C -->|writes logs & serves files| SITES
    SS -.->|mounted from| CONF

    U1[Client: example.com] --> C
    U2[Client: api.myservice.de] --> C
    C --> B1[upstream backend 1]
    C --> B2[upstream backend 2]
```

### Module Responsibilities

1. **`deploy/Caddyfile`** — Main Caddy configuration: global settings (ACME
   email, admin API bind), import glob for site snippets.
2. **`deploy/sites/example.com.caddy`** — Example site snippet demonstrating
   reverse proxy + static files + logging.
3. **`deploy/run`** — Container entrypoint: starts Caddy, polls for config
   changes, triggers graceful reloads.
4. **`deploy/Containerfile`** — Multi-stage container build with updated
   volumes and directory structure.
5. **`Makefile`** — Updated `run-container` target with correct volume mounts.

## Execution Paths

### Path 1: Container startup with site configs

1. `deploy/run` — entrypoint starts, reads `CADDYFILE` and `RELOAD_INTERVAL`
   env vars.
2. `deploy/run` — starts `httpsvc run --config $CADDYFILE --adapter caddyfile`
   as a background process, captures PID.
3. Caddy reads `/etc/caddy/Caddyfile` → processes `import /etc/caddy/sites/*.caddy`
   → loads all site configurations.
4. Caddy obtains/loads TLS certificates from `/data/caddy/certificates/`.
5. Caddy begins serving traffic on ports 80 and 443.
6. `deploy/run` — enters polling loop, recording initial config state.

### Path 2: Hot-reload after config change

1. Operator adds/modifies a `.caddy` file in `/etc/caddy/sites/`.
2. `deploy/run` — polling loop detects directory mtime change.
3. `deploy/run` — runs `httpsvc reload --config $CADDYFILE --adapter caddyfile`.
4. Caddy admin API (localhost:2019) receives the new config.
5. Caddy validates the config — if valid, applies gracefully; if invalid, logs
   error and keeps current config.
6. `deploy/run` — logs reload result to stdout.

### Path 3: Static file request with proxy fallback

1. Client sends `GET /logo.png` to `example.com`.
2. Caddy matches `example.com` site block.
3. Caddy evaluates `@static file` matcher against `/sites/example.com/static/logo.png`.
4. File exists → Caddy serves it with `file_server` and appropriate MIME type.
5. (Alternative) File does not exist → Caddy forwards to `reverse_proxy upstream:port`.

### Path 4: Graceful shutdown

1. Container runtime sends SIGTERM to entrypoint.
2. `deploy/run` — trap handler forwards SIGTERM to Caddy PID.
3. Caddy gracefully drains active connections and exits.
4. `deploy/run` — waits for Caddy process to exit, then exits itself.

## Components and Interfaces

### Main Caddyfile (`deploy/Caddyfile`)

```caddyfile
{
    email {$ACME_EMAIL:no-reply@localhost}
    admin localhost:2019
}

import /etc/caddy/sites/*.caddy
```

### Site Snippet Template (`deploy/sites/example.com.caddy`)

```caddyfile
example.com {
    root * /sites/example.com/static

    log {
        output file /sites/example.com/logs/access.log
        format json
    }

    @static file
    handle @static {
        file_server
    }

    handle {
        reverse_proxy localhost:8080
    }
}
```

### Entrypoint Script (`deploy/run`)

```
Usage: /usr/local/bin/run

Environment variables:
  CADDYFILE         Path to main Caddyfile (default: /etc/caddy/Caddyfile)
  RELOAD_INTERVAL   Poll interval in seconds (default: 30)

Behavior:
  1. Start Caddy as background process
  2. Set up SIGTERM/SIGINT trap to forward to Caddy
  3. Poll config directory mtime every RELOAD_INTERVAL seconds
  4. On change: run httpsvc reload, log result
  5. On signal: forward to Caddy, wait, exit
```

## Data Models

### Site Snippet File Naming

- Pattern: `<domain>.caddy`
- Examples: `example.com.caddy`, `api.myservice.de.caddy`
- Location: `/etc/caddy/sites/`

### Directory Structure Per Site

```
/sites/<domain>/
  logs/
    access.log       # Caddy JSON access log
  static/
    index.html       # Optional default page
    ...              # Any static assets
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ACME_EMAIL` | `no-reply@localhost` | Let's Encrypt account email |
| `CADDYFILE` | `/etc/caddy/Caddyfile` | Path to main config |
| `RELOAD_INTERVAL` | `30` | Config poll interval (seconds) |
| `XDG_CONFIG_HOME` | `/config` | Caddy config directory |
| `XDG_DATA_HOME` | `/data` | Caddy data directory (certs) |

## Operational Readiness

### Observability

- Caddy's built-in Prometheus metrics remain available on the admin API
  (localhost:2019/metrics).
- Per-site access logs in JSON format under `/sites/<domain>/logs/`.
- Entrypoint logs reload events (success/failure) to container stdout.

### Rollback

- Reverting a site: delete its `.caddy` file; next poll cycle removes the site.
- Reverting all changes: restore the previous `/etc/caddy/sites/` directory
  content; Caddy reloads to the previous state.
- Certificates persist in `/data` and are unaffected by config rollbacks.

## Correctness Properties

### Property 1: Import Completeness

*For any* set of `.caddy` files in `/etc/caddy/sites/`, the running Caddy
configuration SHALL include a site block for every file in the directory after
a reload.

**Validates: Requirements 1.1, 1.2, 1.3**

### Property 2: Certificate Persistence

*For any* domain that has previously obtained a TLS certificate, restarting the
container with the same `/data` volume SHALL result in Caddy reusing the
existing certificate without issuing a new ACME request.

**Validates: Requirements 2.1, 2.2**

### Property 3: Log Isolation

*For any* two active sites A and B, all log entries for requests to site A
SHALL be written exclusively to `/sites/A/logs/access.log` and never to
`/sites/B/logs/access.log`.

**Validates: Requirements 3.1**

### Property 4: Static-Then-Proxy Precedence

*For any* request to a site with both static files and an upstream configured,
if a file exists at the requested path under `/sites/<domain>/static/`, the
response SHALL be served from disk; otherwise the request SHALL be forwarded
to the upstream.

**Validates: Requirements 4.1, 4.2**

### Property 5: Reload Timeliness

*For any* configuration change (file added, removed, or modified in
`/etc/caddy/sites/`), the system SHALL trigger a reload within
`RELOAD_INTERVAL` seconds of the change.

**Validates: Requirements 5.1, 5.2, 5.3**

### Property 6: Reload Failure Isolation

*For any* reload triggered by an invalid configuration, the system SHALL
continue serving the previous valid configuration without interruption.

**Validates: Requirements 1.E2, 5.E1**

### Property 7: Admin API Confinement

*For any* network interface on the container other than loopback, the admin API
SHALL NOT be reachable.

**Validates: Requirements 6.1, 6.2**

## Error Handling

| Error Condition | Behavior | Requirement |
|----------------|----------|-------------|
| No site snippets on startup | Start successfully, serve no sites | 01-REQ-1.E1 |
| Invalid site snippet syntax (reload) | Log error, keep previous config | 01-REQ-1.E2 |
| Empty `/data` volume on first start | Obtain new certs automatically | 01-REQ-2.E1 |
| `/sites` volume not mounted | Write logs to ephemeral filesystem | 01-REQ-3.E1 |
| Static dir empty/missing | Proxy all requests (or 404 if no upstream) | 01-REQ-4.E1 |
| Reload fails (invalid config) | Log error, serve last valid config | 01-REQ-5.E1 |
| Invalid `RELOAD_INTERVAL` value | Default to 30s, log warning | 01-REQ-5.E2 |
| Admin API unreachable during reload | Log error, retry next cycle | 01-REQ-6.E1 |

## Technology Stack

- **Runtime:** Caddy v2.9.1 (via Go binary `httpsvc`)
- **Language:** Shell (POSIX sh for entrypoint script)
- **Container base:** UBI 10 micro (runtime), UBI 10 go-toolset (build)
- **Container tool:** Podman (multi-arch manifest builds)
- **TLS:** Let's Encrypt via Caddy's built-in CertMagic/ACME

## Definition of Done

A task group is complete when ALL of the following are true:

1. All subtasks within the group are checked off (`[x]`)
2. All spec tests (`test_spec.md` entries) for the task group pass
3. All property tests for the task group pass
4. All previously passing tests still pass (no regressions)
5. No linter warnings or errors introduced
6. Code is committed on a feature branch and merged into `develop`
7. Feature branch is merged back to `develop`
8. `tasks.md` checkboxes are updated to reflect completion

## Testing Strategy

This project is configuration-driven (Caddyfile, shell scripts, Containerfile)
with no custom Go code. Testing focuses on:

1. **Shell script tests (unit):** Validate entrypoint logic — interval parsing,
   signal handling, change detection — using BATS (Bash Automated Testing
   System) or direct invocation with assertions.
2. **Caddyfile validation tests (unit):** Run `httpsvc validate --config ...
   --adapter caddyfile` against the main Caddyfile and example snippets.
3. **Container integration tests:** Build the image, start a container with
   test site configs, verify HTTP responses, log output, and hot-reload
   behavior using `curl` and podman.
4. **Property tests** are implemented as parameterised integration tests that
   verify invariants (e.g. log isolation, static-then-proxy precedence) across
   multiple site configurations.
