# Test Specification: Multi-Site Reverse Proxy

## Overview

Tests are organised into three tiers: (1) unit tests for Caddyfile validation
and entrypoint script logic, (2) integration tests that start a container and
verify HTTP behavior, and (3) property tests that verify invariants across
multiple configurations. All tests use shell scripts and `curl` — no Go test
code is needed since the project has no custom Go modules.

Test commands:
- `make test` — runs Go tests (currently a no-op; kept for future modules)
- `make test-integration` — builds the image and runs container-based tests
- `httpsvc validate --config deploy/Caddyfile --adapter caddyfile` — validates config

## Test Cases

### TS-01-1: Main Caddyfile imports site snippets

**Requirement:** 01-REQ-1.3
**Type:** unit
**Description:** The main Caddyfile contains an import glob for site snippets.

**Preconditions:**
- `deploy/Caddyfile` exists.

**Input:**
- Content of `deploy/Caddyfile`.

**Expected:**
- The file contains the directive `import /etc/caddy/sites/*.caddy`.

**Assertion pseudocode:**
```
content = read_file("deploy/Caddyfile")
ASSERT "import /etc/caddy/sites/*.caddy" IN content
```

### TS-01-2: Main Caddyfile configures admin API on localhost

**Requirement:** 01-REQ-6.1
**Type:** unit
**Description:** The admin API is bound to localhost only.

**Preconditions:**
- `deploy/Caddyfile` exists.

**Input:**
- Content of `deploy/Caddyfile`.

**Expected:**
- The file contains `admin localhost:2019`.

**Assertion pseudocode:**
```
content = read_file("deploy/Caddyfile")
ASSERT "admin localhost:2019" IN content
```

### TS-01-3: Caddyfile validates successfully with example snippet

**Requirement:** 01-REQ-1.1
**Type:** unit
**Description:** Caddy accepts the main Caddyfile with an example site snippet.

**Preconditions:**
- `deploy/Caddyfile` and `deploy/sites/example.com.caddy` exist.
- The import path in the Caddyfile is adjusted to `deploy/sites/*.caddy` for
  local testing (or a temp directory is used).

**Input:**
- Run `httpsvc validate --config <caddyfile> --adapter caddyfile`.

**Expected:**
- Exit code 0 (valid configuration).

**Assertion pseudocode:**
```
exit_code = run("httpsvc validate --config <caddyfile> --adapter caddyfile")
ASSERT exit_code == 0
```

### TS-01-4: Example site snippet has correct log output path

**Requirement:** 01-REQ-3.1
**Type:** unit
**Description:** The example snippet logs to the per-site log directory.

**Preconditions:**
- `deploy/sites/example.com.caddy` exists.

**Input:**
- Content of the example site snippet.

**Expected:**
- Contains `output file /sites/example.com/logs/access.log`.
- Contains `format json`.

**Assertion pseudocode:**
```
content = read_file("deploy/sites/example.com.caddy")
ASSERT "output file /sites/example.com/logs/access.log" IN content
ASSERT "format json" IN content
```

### TS-01-5: Example site snippet has correct static root

**Requirement:** 01-REQ-4.3
**Type:** unit
**Description:** The example snippet sets root to the per-site static directory.

**Preconditions:**
- `deploy/sites/example.com.caddy` exists.

**Input:**
- Content of the example site snippet.

**Expected:**
- Contains `root * /sites/example.com/static`.

**Assertion pseudocode:**
```
content = read_file("deploy/sites/example.com.caddy")
ASSERT "root * /sites/example.com/static" IN content
```

### TS-01-6: Example site snippet uses file_server with static matcher

**Requirement:** 01-REQ-4.1, 01-REQ-4.2
**Type:** unit
**Description:** Static files are served first, with reverse proxy as fallback.

**Preconditions:**
- `deploy/sites/example.com.caddy` exists.

**Input:**
- Content of the example site snippet.

**Expected:**
- Contains `@static file` matcher.
- Contains `handle @static` block with `file_server`.
- Contains a fallback `handle` block with `reverse_proxy`.

**Assertion pseudocode:**
```
content = read_file("deploy/sites/example.com.caddy")
ASSERT "@static file" IN content
ASSERT "file_server" IN content
ASSERT "reverse_proxy" IN content
```

### TS-01-7: Containerfile does not expose port 2019

**Requirement:** 01-REQ-6.2
**Type:** unit
**Description:** The admin API port is not exposed in the container image.

**Preconditions:**
- `deploy/Containerfile` exists.

**Input:**
- Content of `deploy/Containerfile`.

**Expected:**
- No `EXPOSE 2019` directive.

**Assertion pseudocode:**
```
content = read_file("deploy/Containerfile")
ASSERT "EXPOSE 2019" NOT IN content
```

### TS-01-8: Containerfile declares /sites volume

**Requirement:** 01-REQ-3.3
**Type:** unit
**Description:** The container declares a volume for per-site data.

**Preconditions:**
- `deploy/Containerfile` exists.

**Input:**
- Content of `deploy/Containerfile`.

**Expected:**
- Contains `VOLUME /sites` (or `/sites` in a VOLUME list).

**Assertion pseudocode:**
```
content = read_file("deploy/Containerfile")
ASSERT "VOLUME" IN content AND "/sites" IN content
```

### TS-01-9: Entrypoint uses RELOAD_INTERVAL with default 30

**Requirement:** 01-REQ-5.3
**Type:** unit
**Description:** The entrypoint reads RELOAD_INTERVAL and defaults to 30.

**Preconditions:**
- `deploy/run` exists.

**Input:**
- Content of `deploy/run`.

**Expected:**
- References `RELOAD_INTERVAL` variable.
- Uses a default of `30`.

**Assertion pseudocode:**
```
content = read_file("deploy/run")
ASSERT "RELOAD_INTERVAL" IN content
ASSERT default_value("RELOAD_INTERVAL") == "30"
```

### TS-01-10: Entrypoint logs reload attempts

**Requirement:** 01-REQ-5.2
**Type:** unit
**Description:** The entrypoint logs when it attempts a reload.

**Preconditions:**
- `deploy/run` exists.

**Input:**
- Content of `deploy/run`.

**Expected:**
- Contains log output statements for reload events (e.g. echo/printf to stdout).

**Assertion pseudocode:**
```
content = read_file("deploy/run")
ASSERT content contains logging around the reload command
```

## Edge Case Tests

### TS-01-E1: Caddy starts with empty sites directory

**Requirement:** 01-REQ-1.E1
**Type:** integration
**Description:** Caddy starts successfully when no site snippets exist.

**Preconditions:**
- Container image built.
- `/etc/caddy/sites/` directory is empty.

**Input:**
- Start container with empty sites directory.

**Expected:**
- Container starts without error (exit code 0 while running).
- No sites are served (connections to port 80/443 are refused or return no
  matching host).

**Assertion pseudocode:**
```
container = start_container(sites_dir=empty)
ASSERT container.is_running()
result = curl("http://localhost:80")
ASSERT result.status != 200 OR result contains no site content
stop_container(container)
```

### TS-01-E2: Reload with invalid snippet keeps old config

**Requirement:** 01-REQ-1.E2, 01-REQ-5.E1
**Type:** integration
**Description:** An invalid config file does not break existing sites.

**Preconditions:**
- Container running with one valid site snippet serving HTTP 200.

**Input:**
- Add a syntactically invalid `.caddy` file to the sites directory.
- Wait for reload cycle.

**Expected:**
- Reload logs an error.
- The previously working site continues to serve HTTP 200.

**Assertion pseudocode:**
```
container = start_container(sites=["valid.caddy"])
ASSERT curl("http://valid-site") == 200
add_file(sites_dir, "broken.caddy", content="{{{{invalid")
wait(RELOAD_INTERVAL + 5)
logs = container.logs()
ASSERT "error" IN logs.lower()
ASSERT curl("http://valid-site") == 200
```

### TS-01-E4: First start with empty data volume obtains certificates

**Requirement:** 01-REQ-2.E1
**Type:** integration
**Description:** Caddy obtains new certificates when the data volume is fresh.

**Preconditions:**
- Container image built.
- `/data` volume is empty (no prior certificate state).
- A site snippet with a valid domain is configured.

**Input:**
- Start container with an empty `/data` volume and a site snippet.

**Expected:**
- Container starts and obtains certificates (or attempts to, which may fail
  in test environments without real DNS — the test verifies the attempt
  is made by checking ACME-related log entries).

**Assertion pseudocode:**
```
container = start_container(sites=["test-domain.caddy"], data_volume=empty)
ASSERT container.is_running()
logs = container.logs()
ASSERT "obtaining" IN logs.lower() OR "acme" IN logs.lower() OR "certificate" IN logs.lower()
```

### TS-01-E5: Sites volume not mounted falls back to ephemeral storage

**Requirement:** 01-REQ-3.E1
**Type:** integration
**Description:** Without a `/sites` mount, logs are written to the container's
ephemeral filesystem.

**Preconditions:**
- Container image built.
- No `/sites` volume mounted (uses image default).

**Input:**
- Start container with a site snippet but no external sites volume.
- Send a request to generate a log entry.

**Expected:**
- Container starts successfully.
- Caddy writes the log inside the container filesystem (verifiable via
  `podman exec`).

**Assertion pseudocode:**
```
container = start_container(sites=["test-domain.caddy"], no_sites_volume=true)
ASSERT container.is_running()
curl("http://test-domain/")
log = exec_in_container(container, "cat /sites/test-domain/logs/access.log")
ASSERT len(log) > 0
```

### TS-01-E6: Empty static directory proxies all requests

**Requirement:** 01-REQ-4.E1
**Type:** integration
**Description:** When no static files exist, all requests go to the upstream.

**Preconditions:**
- Container running with a site snippet that has a reverse proxy configured.
- Static directory exists but is empty.

**Input:**
- Request any path.

**Expected:**
- Response comes from the upstream, not a 404.

**Assertion pseudocode:**
```
upstream = start_http_server(response="UPSTREAM RESPONSE")
container = start_container(sites=["test-domain.caddy"], static_dir=empty)
response = curl("http://test-domain/anything")
ASSERT response.body == "UPSTREAM RESPONSE"
```

### TS-01-E7: Admin API unreachable during reload retries next cycle

**Requirement:** 01-REQ-6.E1
**Type:** integration
**Description:** If the admin API is temporarily unreachable, the entrypoint
logs the error and retries on the next poll cycle.

**Preconditions:**
- Container running with a site snippet.

**Input:**
- Simulate admin API unavailability (e.g. by temporarily stopping Caddy
  inside the container), then add a config change.

**Expected:**
- Entrypoint logs a reload error.
- On the next cycle (after Caddy is restarted or recovers), reload succeeds.

**Assertion pseudocode:**
```
container = start_container(sites=["test-domain.caddy"], env={"RELOAD_INTERVAL": "5"})
exec_in_container(container, "kill -STOP $(pidof httpsvc)")
add_config_change()
wait(10)
logs = container.logs()
ASSERT "error" IN logs.lower() OR "failed" IN logs.lower()
exec_in_container(container, "kill -CONT $(pidof httpsvc)")
wait(10)
ASSERT reload eventually succeeds in logs
```

### TS-01-E3: Invalid RELOAD_INTERVAL defaults to 30

**Requirement:** 01-REQ-5.E2
**Type:** integration
**Description:** Non-numeric RELOAD_INTERVAL falls back to default.

**Preconditions:**
- Container image built.

**Input:**
- Start container with `RELOAD_INTERVAL=abc`.

**Expected:**
- Container starts successfully.
- Container logs contain a warning about the invalid interval.
- Effective interval is 30 seconds.

**Assertion pseudocode:**
```
container = start_container(env={"RELOAD_INTERVAL": "abc"})
ASSERT container.is_running()
logs = container.logs()
ASSERT "warning" IN logs.lower() OR "invalid" IN logs.lower()
ASSERT "30" IN logs
```

## Property Test Cases

### TS-01-P1: Import Completeness

**Property:** Property 1 from design.md
**Validates:** 01-REQ-1.1, 01-REQ-1.2, 01-REQ-1.3
**Type:** property
**Description:** Every site snippet in the config directory is included after
reload.

**For any:** set of 1-5 valid site snippet files with distinct domain names.
**Invariant:** After Caddy loads, each domain responds to HTTP requests.

**Assertion pseudocode:**
```
FOR ANY domains IN generate_domains(1, 5):
    create_snippets(domains)
    reload_caddy()
    FOR EACH domain IN domains:
        ASSERT curl("http://{domain}") returns a response (not connection refused)
```

### TS-01-P2: Certificate Persistence

**Property:** Property 2 from design.md
**Validates:** 01-REQ-2.1, 01-REQ-2.2
**Type:** property
**Description:** Certificates survive container restarts when the data volume
is preserved.

**For any:** domain that has previously obtained a TLS certificate.
**Invariant:** Restarting the container with the same `/data` volume results in
Caddy reusing the existing certificate without issuing a new ACME request.

**Assertion pseudocode:**
```
FOR ANY domain IN ["test-a.example.com"]:
    container1 = start_container(sites=[domain], volume="caddy-data:/data")
    wait_for_cert(domain)
    cert_files_before = list_files("/data/caddy/certificates/")
    stop_container(container1)
    container2 = start_container(sites=[domain], volume="caddy-data:/data")
    cert_files_after = list_files("/data/caddy/certificates/")
    ASSERT cert_files_before == cert_files_after
    ASSERT no new ACME requests in container2 logs
```

### TS-01-P3: Log Isolation

**Property:** Property 3 from design.md
**Validates:** 01-REQ-3.1
**Type:** property
**Description:** Requests to site A produce logs only in site A's log directory.

**For any:** two distinct sites A and B both active.
**Invariant:** A request to site A produces a log entry only in
`/sites/A/logs/access.log`, not in `/sites/B/logs/access.log`.

**Assertion pseudocode:**
```
FOR ANY (siteA, siteB) IN pairs_of_domains():
    start_with_sites([siteA, siteB])
    curl("http://{siteA}/test")
    logA = read("/sites/{siteA}/logs/access.log")
    logB = read("/sites/{siteB}/logs/access.log")
    ASSERT "/test" IN logA
    ASSERT "/test" NOT IN logB
```

### TS-01-P4: Static-Then-Proxy Precedence

**Property:** Property 4 from design.md
**Validates:** 01-REQ-4.1, 01-REQ-4.2
**Type:** property
**Description:** Static files take precedence over reverse proxy.

**For any:** site with both static files and upstream, and a request path that
exists as a static file.
**Invariant:** The static file content is returned; the upstream is not
contacted.

**Assertion pseudocode:**
```
FOR ANY path IN ["/index.html", "/logo.png", "/styles.css"]:
    create_static_file(domain, path, content="STATIC:{path}")
    response = curl("http://{domain}{path}")
    ASSERT response.body == "STATIC:{path}"
    ASSERT upstream.request_count == 0 for path
```

### TS-01-P5: Reload Timeliness

**Property:** Property 5 from design.md
**Validates:** 01-REQ-5.1, 01-REQ-5.2, 01-REQ-5.3
**Type:** property
**Description:** Config changes trigger a reload within the poll interval.

**For any:** valid RELOAD_INTERVAL in {10, 30, 60}.
**Invariant:** A new site snippet added to the config directory is live within
RELOAD_INTERVAL + 5 seconds (allowing for processing overhead).

**Assertion pseudocode:**
```
FOR ANY interval IN [10, 30, 60]:
    container = start_container(env={"RELOAD_INTERVAL": str(interval)})
    add_snippet("new-site.caddy")
    start_time = now()
    WHILE now() - start_time < interval + 5:
        IF curl("http://new-site") == 200:
            elapsed = now() - start_time
            ASSERT elapsed <= interval + 5
            BREAK
    ASSERT site_is_live("new-site")
```

### TS-01-P6: Reload Failure Isolation

**Property:** Property 6 from design.md
**Validates:** 01-REQ-1.E2, 01-REQ-5.E1
**Type:** property
**Description:** Failed reloads do not affect the running configuration.

**For any:** running configuration with N valid sites and a reload triggered by
an invalid config addition.
**Invariant:** All N sites continue to respond with HTTP 200 after the failed
reload.

**Assertion pseudocode:**
```
FOR ANY n IN [1, 2, 3]:
    sites = generate_valid_sites(n)
    container = start_container(sites=sites)
    FOR EACH site IN sites:
        ASSERT curl("http://{site}") == 200
    add_invalid_snippet()
    wait(RELOAD_INTERVAL + 5)
    FOR EACH site IN sites:
        ASSERT curl("http://{site}") == 200
```

### TS-01-P7: Admin API Confinement

**Property:** Property 7 from design.md
**Validates:** 01-REQ-6.1, 01-REQ-6.2
**Type:** property
**Description:** The admin API is not reachable from outside the container.

**For any:** container running with default configuration.
**Invariant:** Connecting to port 2019 from the host fails (connection refused
or timeout), while the admin API is accessible from inside the container on
localhost.

**Assertion pseudocode:**
```
FOR ANY config IN [default_config]:
    container = start_container(sites=["test-domain.caddy"])
    external = curl("http://localhost:2019/config/", timeout=2)
    ASSERT external fails (connection refused or timeout)
    internal = exec_in_container(container, "curl -s http://localhost:2019/config/")
    ASSERT internal.status == 200
```

## Integration Smoke Tests

### TS-01-SMOKE-1: Full startup with site configs

**Execution Path:** Path 1 from design.md
**Description:** Container starts with site configs and serves traffic.

**Setup:** Build the container image. Prepare a sites config directory with one
valid site snippet pointing to a test upstream (a simple HTTP server returning
"UPSTREAM OK"). Prepare a `/sites/` directory with a static `index.html`.

**Trigger:** `podman run` with volume mounts for sites config, sites data, and
data volumes.

**Expected side effects:**
- Container is running (not crashed).
- `curl http://test-domain/` returns content (static file or upstream response).
- Log file exists at `/sites/test-domain/logs/access.log` with at least one
  JSON entry.

**Must NOT satisfy with:** Do not mock Caddy or the entrypoint script. The real
`httpsvc` binary must start and serve requests.

**Assertion pseudocode:**
```
upstream = start_http_server(port=9999, response="UPSTREAM OK")
container = podman_run(
    image="httpsvc:latest",
    volumes={
        sites_config: "/etc/caddy/sites",
        sites_data: "/sites",
        data: "/data"
    },
    env={"HTTPSVC_LISTEN": "http://"}
)
ASSERT container.is_running()
response = curl("http://localhost/")
ASSERT response.status == 200
log_content = read_container_file(container, "/sites/test-domain/logs/access.log")
ASSERT len(log_content) > 0
ASSERT json.loads(log_content.splitlines()[0]) is valid JSON
```

### TS-01-SMOKE-2: Hot-reload adds new site

**Execution Path:** Path 2 from design.md
**Description:** Adding a site config triggers a reload and the new site
becomes live.

**Setup:** Container running with one initial site. A second site snippet
ready to be copied in.

**Trigger:** Copy a new `.caddy` file into the mounted sites config directory.

**Expected side effects:**
- Container logs show a reload message.
- The new site responds to HTTP requests within `RELOAD_INTERVAL + 5` seconds.

**Must NOT satisfy with:** Do not bypass the polling loop. The reload must be
triggered by the entrypoint's change detection, not by a manual `caddy reload`.

**Assertion pseudocode:**
```
container = start_container(sites=["site-a.caddy"], env={"RELOAD_INTERVAL": "10"})
ASSERT curl("http://site-a") == 200
copy_file("site-b.caddy", sites_config_dir)
wait_until(lambda: curl("http://site-b") == 200, timeout=15)
logs = container.logs()
ASSERT "reload" IN logs.lower()
```

### TS-01-SMOKE-3: Static file served, proxy fallback for missing files

**Execution Path:** Path 3 from design.md
**Description:** Existing static files are served directly; missing files fall
through to the upstream proxy.

**Setup:** Container running with one site. Static directory contains
`index.html`. Upstream server returns "FROM PROXY".

**Trigger:** Request a static file path and a non-static file path.

**Expected side effects:**
- `GET /index.html` returns the static file content.
- `GET /api/data` returns "FROM PROXY" from the upstream.

**Must NOT satisfy with:** Do not mock the file system or Caddy's file_server.
Real files must exist on disk and be served by Caddy.

**Assertion pseudocode:**
```
create_static_file("/sites/test-domain/static/index.html", "STATIC PAGE")
upstream = start_http_server(response="FROM PROXY")
container = start_container(sites=["test-domain.caddy"])
ASSERT curl("http://test-domain/index.html").body == "STATIC PAGE"
ASSERT curl("http://test-domain/api/data").body == "FROM PROXY"
```

### TS-01-SMOKE-4: Graceful shutdown

**Execution Path:** Path 4 from design.md
**Description:** SIGTERM causes graceful shutdown without error.

**Setup:** Container running with at least one site.

**Trigger:** `podman stop` (sends SIGTERM).

**Expected side effects:**
- Container exits with code 0.
- No error messages in container logs related to shutdown.

**Must NOT satisfy with:** Do not use `podman kill` (SIGKILL). The test
verifies graceful shutdown via SIGTERM.

**Assertion pseudocode:**
```
container = start_container(sites=["test-domain.caddy"])
ASSERT container.is_running()
podman_stop(container)
exit_code = container.wait()
ASSERT exit_code == 0
logs = container.logs()
ASSERT "error" NOT IN logs related to shutdown
```

## Coverage Matrix

| Requirement | Test Spec Entry | Type |
|-------------|-----------------|------|
| 01-REQ-1.1 | TS-01-1, TS-01-3 | unit |
| 01-REQ-1.2 | TS-01-P1 | property |
| 01-REQ-1.3 | TS-01-1 | unit |
| 01-REQ-1.E1 | TS-01-E1 | integration |
| 01-REQ-1.E2 | TS-01-E2, TS-01-P6 | integration, property |
| 01-REQ-2.1 | TS-01-SMOKE-1 | integration |
| 01-REQ-2.2 | TS-01-SMOKE-1 | integration |
| 01-REQ-2.3 | TS-01-8 | unit |
| 01-REQ-2.E1 | TS-01-E4, TS-01-SMOKE-1 | integration |
| 01-REQ-3.1 | TS-01-4, TS-01-P3 | unit, property |
| 01-REQ-3.2 | TS-01-SMOKE-1 | integration |
| 01-REQ-3.3 | TS-01-8 | unit |
| 01-REQ-3.E1 | TS-01-E5 | integration |
| 01-REQ-4.1 | TS-01-6, TS-01-P4 | unit, property |
| 01-REQ-4.2 | TS-01-6, TS-01-P4 | unit, property |
| 01-REQ-4.3 | TS-01-5 | unit |
| 01-REQ-4.E1 | TS-01-E6 | integration |
| 01-REQ-5.1 | TS-01-9, TS-01-P5 | unit, property |
| 01-REQ-5.2 | TS-01-10, TS-01-SMOKE-2 | unit, integration |
| 01-REQ-5.3 | TS-01-9, TS-01-P5 | unit, property |
| 01-REQ-5.4 | TS-01-SMOKE-2 | integration |
| 01-REQ-5.E1 | TS-01-E2, TS-01-P6 | integration, property |
| 01-REQ-5.E2 | TS-01-E3 | integration |
| 01-REQ-6.1 | TS-01-2 | unit |
| 01-REQ-6.2 | TS-01-7 | unit |
| 01-REQ-6.E1 | TS-01-E7 | integration |
| Property 1 | TS-01-P1 | property |
| Property 2 | TS-01-P2 | property |
| Property 3 | TS-01-P3 | property |
| Property 4 | TS-01-P4 | property |
| Property 5 | TS-01-P5 | property |
| Property 6 | TS-01-P6 | property |
| Property 7 | TS-01-P7 | property |
