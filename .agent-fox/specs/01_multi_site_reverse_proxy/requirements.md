# Requirements Document

## Introduction

httpsvc is a containerised Caddy reverse-proxy service that serves one or more
domains with automatic TLS via Let's Encrypt. Configuration is file-driven:
each domain is defined in a per-site Caddyfile snippet, and changes are
picked up automatically via periodic reload.

## Glossary

| Term | Definition |
|------|------------|
| Site snippet | A Caddyfile fragment in `/etc/caddy/sites/` describing one domain's routing, logging, and static-file configuration. File extension `.caddy`. |
| Upstream | The backend HTTP server that a reverse-proxy site forwards requests to (e.g. `http://backend:8080`). |
| Hot-reload | The process of detecting configuration changes on disk and applying them to the running Caddy instance without dropping connections. |
| Admin API | Caddy's built-in HTTP API on port 2019 used to reload configuration programmatically. |
| Sites directory | The `/sites/<domain>/` tree containing per-site log and static-file directories. |
| Config directory | `/etc/caddy/sites/` — the directory where site snippet files are stored. |
| Static directory | `/sites/<domain>/static/` — the directory from which static files are served for a given domain. |
| Poll interval | The time in seconds between consecutive checks for configuration changes (default 30). |

## Requirements

### Requirement 1: Multi-Site Serving

**User Story:** As an operator, I want to serve multiple domains from a single
container, so that I can consolidate reverse-proxy infrastructure.

#### Acceptance Criteria

[01-REQ-1.1] WHEN a valid site snippet file exists in `/etc/caddy/sites/`,
THE system SHALL include that site's configuration when Caddy loads or reloads.

[01-REQ-1.2] WHEN multiple site snippet files exist, THE system SHALL serve
all configured domains concurrently.

[01-REQ-1.3] THE main Caddyfile SHALL import all files matching the glob
pattern `/etc/caddy/sites/*.caddy`.

#### Edge Cases

[01-REQ-1.E1] IF no site snippet files exist in `/etc/caddy/sites/`, THEN THE
system SHALL start successfully and serve no sites until a snippet is added.

[01-REQ-1.E2] IF a site snippet contains invalid Caddyfile syntax, THEN THE
system SHALL log the validation error and continue serving the previously
valid configuration.

### Requirement 2: TLS Certificate Persistence

**User Story:** As an operator, I want TLS certificates to survive container
restarts, so that I avoid unnecessary re-issuance and rate-limit hits.

#### Acceptance Criteria

[01-REQ-2.1] THE system SHALL store all TLS certificates and ACME state
under the `/data` volume (at `$XDG_DATA_HOME/caddy/`).

[01-REQ-2.2] WHEN the container restarts with the same `/data` volume
mounted, THE system SHALL reuse previously obtained certificates without
re-requesting them from Let's Encrypt.

[01-REQ-2.3] THE Containerfile SHALL declare `/data` as a named volume.

#### Edge Cases

[01-REQ-2.E1] IF the `/data` volume is empty on first start, THEN THE system
SHALL obtain new certificates from Let's Encrypt automatically.

### Requirement 3: Per-Site Log Directories

**User Story:** As an operator, I want each site's access logs in a separate
directory, so that I can monitor and troubleshoot sites independently.

#### Acceptance Criteria

[01-REQ-3.1] WHEN a site snippet is active, THE system SHALL write structured
JSON access logs to `/sites/<domain>/logs/access.log`.

[01-REQ-3.2] THE system SHALL create the log directory for a site if it does
not already exist, by ensuring the directory structure is present before Caddy
writes logs.

[01-REQ-3.3] THE Containerfile SHALL declare `/sites` as a named volume.

#### Edge Cases

[01-REQ-3.E1] IF the `/sites` volume is not mounted, THEN THE system SHALL
still start and write logs to the ephemeral container filesystem.

### Requirement 4: Per-Site Static File Serving

**User Story:** As an operator, I want each site to serve static assets from
its own directory, so that I can deploy site-specific files (images, default
pages) without rebuilding the container.

#### Acceptance Criteria

[01-REQ-4.1] WHEN a request matches an existing file in
`/sites/<domain>/static/`, THE system SHALL serve that file directly with
appropriate MIME types.

[01-REQ-4.2] WHEN a request does not match any file in the static directory
AND the site has an upstream configured, THE system SHALL forward the request
to the upstream via reverse proxy.

[01-REQ-4.3] Each site snippet SHALL set `root` to `/sites/<domain>/static/`
for static file resolution.

#### Edge Cases

[01-REQ-4.E1] IF the static directory for a site is empty or does not exist,
THEN THE system SHALL proxy all requests to the upstream (or return 404 if no
upstream is configured).

### Requirement 5: Configuration Hot-Reload

**User Story:** As an operator, I want configuration changes to take effect
automatically within 60 seconds, so that I can add or update sites without
restarting the container.

#### Acceptance Criteria

[01-REQ-5.1] THE entrypoint script SHALL poll the config directory for changes
at an interval not exceeding 30 seconds.

[01-REQ-5.2] WHEN a change is detected in the config directory (file added,
removed, or modified), THE entrypoint script SHALL trigger a Caddy reload
via `httpsvc reload` AND log the reload attempt and its outcome (success or
failure) to stdout.

[01-REQ-5.3] THE poll interval SHALL be configurable via the
`RELOAD_INTERVAL` environment variable, defaulting to 30 seconds.

[01-REQ-5.4] WHILE a reload is in progress, THE system SHALL continue serving
existing requests without dropping connections.

#### Edge Cases

[01-REQ-5.E1] IF a reload fails due to invalid configuration, THEN THE system
SHALL log the error to stdout and continue serving the last valid
configuration.

[01-REQ-5.E2] IF the `RELOAD_INTERVAL` environment variable is set to a
non-numeric or negative value, THEN THE system SHALL fall back to the default
interval of 30 seconds and log a warning.

### Requirement 6: Admin API Security

**User Story:** As an operator, I want the Caddy admin API locked to localhost,
so that external clients cannot modify the running configuration.

#### Acceptance Criteria

[01-REQ-6.1] THE main Caddyfile SHALL configure the admin API to listen on
`localhost:2019` only.

[01-REQ-6.2] THE Containerfile SHALL NOT expose port 2019.

#### Edge Cases

[01-REQ-6.E1] IF the admin API is unreachable during a reload attempt, THEN
THE entrypoint script SHALL log the error and retry on the next poll cycle.
