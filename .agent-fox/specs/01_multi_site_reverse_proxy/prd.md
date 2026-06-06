# PRD: Multi-Site Reverse Proxy

## Summary

httpsvc is a Caddy-based reverse proxy service that serves one or more domains
simultaneously (e.g. `www.example.com` and `api.myservice.de`). Each domain is
configured via a per-site config snippet dropped into a directory. The service
automatically obtains and renews TLS certificates via Let's Encrypt, persists
them across container restarts, and provides each site with its own log and
static-file directories. Configuration changes are picked up automatically
within 60 seconds without manual intervention.

## Requirements

### Multi-domain reverse proxy

The service proxies traffic for one or more domains. Each domain is defined in
its own Caddyfile snippet under `/etc/caddy/sites/`. The main Caddyfile imports
all snippets via a glob pattern (`import /etc/caddy/sites/*.caddy`). Adding a
new domain means creating a new `.caddy` file in that directory.

Each site snippet defines its own upstream backend URL (e.g.
`reverse_proxy backend-app:8080`). Sites that serve only static content omit
the `reverse_proxy` directive and use `file_server` alone.

### TLS certificate persistence

Caddy stores certificates and ACME state under `$XDG_DATA_HOME/caddy/`
(mapped to `/data/caddy/` in the container). The `/data` volume must be mounted
with a named volume or host-path bind mount in production to survive container
restarts and updates. No layout change is needed — this is Caddy's default
behavior; the requirement is to enforce and document the mount.

### Per-site log directories

Each site writes structured JSON access logs to its own directory under
`/sites/<domain>/logs/`. The `/sites` volume is mounted from the host so logs
are accessible and persist across restarts. JSON is Caddy's default log format
and is easily consumed by log aggregation tools (jq, Loki, Promtail).

### Per-site static file directories

Each site has a static-file directory at `/sites/<domain>/static/`. Static
files are served with `file_server` when a matching file exists on disk;
requests that do not match a static file fall through to the `reverse_proxy`
upstream (if configured). This allows serving a default `index.html`, images,
or other assets alongside a proxied backend.

### Configuration hot-reload

The container entrypoint polls the configuration directory at a configurable
interval (default 30 seconds). When a change is detected (file added, removed,
or modified), the entrypoint runs `httpsvc reload` against Caddy's admin API.
Caddy performs a graceful reload — no connections are dropped. The admin API
listens on `localhost:2019` only (not exposed externally) for security.

## Design Decisions

The following decisions resolve ambiguities in the original prompt.

1. **Reverse proxy targets** — Each per-site `.caddy` snippet specifies its own
   upstream via `reverse_proxy <upstream>`. Sites that serve only static content
   omit the directive. This keeps configuration explicit per site.

2. **Static files vs. reverse proxy precedence** — Static files are checked
   first using Caddy's `@static file` matcher. If a file exists on disk it is
   served; otherwise the request falls through to `reverse_proxy`. This is the
   standard Caddy pattern for hybrid static/proxy sites.

3. **Configuration format** — Per-site Caddyfile snippets in
   `/etc/caddy/sites/*.caddy`, imported by the main Caddyfile via glob. This is
   the most Caddy-native approach: adding a site = dropping a file, removing a
   site = deleting a file. No custom config format or code needed.

4. **Log format** — Caddy structured JSON access logs. JSON is Caddy's default,
   machine-parseable, and compatible with common log pipelines.

5. **Certificate volume** — The existing `/data` volume already stores
   certificates at Caddy's default path (`$XDG_DATA_HOME/caddy/`). The
   requirement is met by documenting and enforcing the named-volume mount in
   `run-container`. No layout change.

6. **Admin API** — Locked to `localhost:2019`. The hot-reload mechanism uses it
   internally; it is not exposed to external networks. Port 2019 is removed
   from the `EXPOSE` list in the Containerfile.

## Directory Layout (Container)

```
/etc/caddy/
  Caddyfile              # main config (global settings + import glob)
  sites/                 # per-site config snippets (mounted volume)
    example.com.caddy
    api.myservice.de.caddy

/sites/                  # per-site data (mounted volume)
  example.com/
    logs/                # access logs (JSON)
    static/              # static assets (index.html, images, …)
  api.myservice.de/
    logs/
    static/

/data/                   # Caddy data (mounted volume)
  caddy/
    certificates/        # Let's Encrypt certs
    locks/
    ocsp/
```

## Source

Source: Input provided by user via interactive prompt
