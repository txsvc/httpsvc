#!/bin/bash
# test/integration/test_container.sh — Integration, edge case, property, and
# smoke tests for the httpsvc container.
#
# Tests: TS-01-E1 through TS-01-E7, TS-01-P1 through TS-01-P7,
#        TS-01-SMOKE-1 through TS-01-SMOKE-4
#
# Prerequisites:
#   - podman installed and available
#   - Container image built: make image
#
# These tests are expected to FAIL until the container is updated.
set -eu

# --- configuration ---
IMAGE="${IMAGE:-httpsvc:latest}"
CONTAINER_NAME_PREFIX="httpsvc-test"
TESTS_RUN=0
TESTS_FAILED=0
TESTS_PASSED=0
TESTS_SKIPPED=0

# --- test harness ---
pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "  PASS: %s\n" "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  FAIL: %s\n" "$1"
}

skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    printf "  SKIP: %s\n" "$1"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf "TEST: %s\n" "$1"
}

# --- helpers ---

# Check that podman is available; skip tests if not
require_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        skip "podman not available"
        return 1
    fi
    return 0
}

# Check that the container image exists; skip tests if not
require_image() {
    if ! podman image exists "${IMAGE}" 2>/dev/null; then
        skip "image ${IMAGE} not found (run 'make image' first)"
        return 1
    fi
    return 0
}

# Generate a unique container name
container_name() {
    printf "%s-%s" "${CONTAINER_NAME_PREFIX}" "$1"
}

# Clean up a container by name (ignore errors)
cleanup_container() {
    podman rm -f "$1" >/dev/null 2>&1 || true
}

# Wait for a container to be running (max 10s)
wait_running() {
    _cname="$1"
    _max=10
    _i=0
    while [ "${_i}" -lt "${_max}" ]; do
        if podman inspect --format '{{.State.Running}}' "${_cname}" 2>/dev/null | grep -q true; then
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

# =====================================================================
# Edge Case Tests (TS-01-E1 through TS-01-E7)
# =====================================================================

# -----------------------------------------------------------------------
# TS-01-E1: Caddy starts with empty sites directory
# Requirement: 01-REQ-1.E1
# -----------------------------------------------------------------------
test_ts01_e1_empty_sites_dir() {
    run_test "TS-01-E1: Caddy starts with empty sites directory"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "e1")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    # Create an empty sites config directory
    mkdir -p "${tmpdir}/sites"

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start with empty sites directory"
        rm -rf "${tmpdir}"
        return
    }

    if wait_running "${cname}"; then
        pass "Container starts with empty sites directory"
    else
        fail "Container did not stay running with empty sites directory"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-E2: Reload with invalid snippet keeps old config
# Requirement: 01-REQ-1.E2, 01-REQ-5.E1
# -----------------------------------------------------------------------
test_ts01_e2_invalid_snippet_reload() {
    run_test "TS-01-E2: Reload with invalid snippet keeps old config"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "e2")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/sitedata/test.local/static" "${tmpdir}/sitedata/test.local/logs"

    # Create a valid site snippet
    cat > "${tmpdir}/sites/test.local.caddy" <<'CADDY'
http://test.local {
    root * /sites/test.local/static
    log {
        output file /sites/test.local/logs/access.log
        format json
    }
    respond "VALID SITE" 200
}
CADDY

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/sitedata:/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -e RELOAD_INTERVAL=5 \
        -p 18096:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2

    # Verify the valid site is serving traffic before adding invalid snippet
    body_before="$(curl -s --resolve "test.local:18096:127.0.0.1" \
        "http://test.local:18096/" 2>/dev/null)" || body_before=""
    if ! printf '%s' "${body_before}" | grep -qF "VALID SITE"; then
        fail "Valid site not serving traffic before invalid snippet was added"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    # Add an invalid snippet
    printf '{{{{invalid syntax' > "${tmpdir}/sites/broken.caddy"

    # Wait for a reload cycle
    sleep 10

    logs="$(podman logs "${cname}" 2>&1)"
    if printf '%s' "${logs}" | grep -qi "error"; then
        pass "Reload logged an error for invalid config"
    else
        fail "No error logged after adding invalid snippet"
    fi

    # Verify the originally-valid site is STILL serving traffic (old config kept)
    body_after="$(curl -s --resolve "test.local:18096:127.0.0.1" \
        "http://test.local:18096/" 2>/dev/null)" || body_after=""
    if printf '%s' "${body_after}" | grep -qF "VALID SITE"; then
        pass "Valid site still serving traffic after failed reload (old config kept)"
    else
        fail "Valid site no longer serving traffic after failed reload (got: ${body_after})"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-E3: Invalid RELOAD_INTERVAL defaults to 30
# Requirement: 01-REQ-5.E2
# -----------------------------------------------------------------------
test_ts01_e3_invalid_reload_interval() {
    run_test "TS-01-E3: Invalid RELOAD_INTERVAL defaults to 30"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "e3")"
    cleanup_container "${cname}"

    podman run -d --name "${cname}" \
        -e RELOAD_INTERVAL=abc \
        -e HTTPSVC_LISTEN="http://" \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start with invalid RELOAD_INTERVAL"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        return
    fi

    logs="$(podman logs "${cname}" 2>&1)"
    local_fail=0

    if printf '%s' "${logs}" | grep -qiE "(warning|invalid)"; then
        pass "Container logged a warning about invalid interval"
    else
        fail "No warning logged for invalid RELOAD_INTERVAL"
        local_fail=1
    fi

    if printf '%s' "${logs}" | grep -qF "30"; then
        pass "Container mentions default interval 30"
    else
        fail "Container does not mention default interval 30 in logs"
        local_fail=1
    fi

    cleanup_container "${cname}"
    return ${local_fail}
}

# -----------------------------------------------------------------------
# TS-01-E4: First start with empty data volume obtains certificates
# Requirement: 01-REQ-2.E1
# -----------------------------------------------------------------------
test_ts01_e4_empty_data_volume() {
    run_test "TS-01-E4: First start with empty data volume obtains certificates"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "e4")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/data"

    # Create a site snippet (will attempt TLS in production; in test we just
    # check that Caddy tries)
    cat > "${tmpdir}/sites/test-cert.example.com.caddy" <<'CADDY'
test-cert.example.com {
    root * /sites/test-cert.example.com/static
    respond "CERT TEST" 200
}
CADDY

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/data:/data:Z" \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    # Give Caddy a moment to attempt certificate operations
    sleep 5

    logs="$(podman logs "${cname}" 2>&1)"
    if printf '%s' "${logs}" | grep -qiE "(obtaining|acme|certificate|tls)"; then
        pass "Caddy attempted certificate acquisition"
    else
        fail "No certificate-related log entries found"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-E5: Sites volume not mounted falls back to ephemeral storage
# Requirement: 01-REQ-3.E1
# -----------------------------------------------------------------------
test_ts01_e5_no_sites_volume() {
    run_test "TS-01-E5: Sites volume not mounted falls back to ephemeral storage"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "e5")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites"

    cat > "${tmpdir}/sites/test.local.caddy" <<'CADDY'
http://test.local {
    root * /sites/test.local/static
    log {
        output file /sites/test.local/logs/access.log
        format json
    }
    respond "EPHEMERAL TEST" 200
}
CADDY

    # Start without external /sites volume mount — uses image default
    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -p 18085:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start without /sites volume"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    # Send a request to generate a log entry
    sleep 2
    curl -s -o /dev/null --resolve test.local:18085:127.0.0.1 \
        "http://test.local:18085/" 2>/dev/null || true

    # Check that log was written to ephemeral filesystem inside container
    log_content="$(podman exec "${cname}" cat /sites/test.local/logs/access.log 2>/dev/null)" || log_content=""
    if [ -n "${log_content}" ]; then
        pass "Logs written to ephemeral filesystem inside container"
    else
        fail "No logs found at /sites/test.local/logs/access.log in container"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-E6: Empty static directory proxies all requests
# Requirement: 01-REQ-4.E1
# -----------------------------------------------------------------------
test_ts01_e6_empty_static_proxies() {
    run_test "TS-01-E6: Empty static directory proxies all requests"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "e6")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/sitedata/test.local/static" "${tmpdir}/sitedata/test.local/logs"

    # Site snippet with reverse proxy to an upstream
    cat > "${tmpdir}/sites/test.local.caddy" <<'CADDY'
http://test.local {
    root * /sites/test.local/static

    @static file
    handle @static {
        file_server
    }

    handle {
        reverse_proxy host.containers.internal:19876
    }
}
CADDY

    # Start a simple upstream (python http server returning known response)
    # Note: this test is a stub — it will be fully wired when the container is updated
    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/sitedata:/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -p 18086:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    # With empty static dir and no upstream running, we expect a 502 (bad gateway)
    # rather than a 404 — proving the proxy path was taken
    sleep 2
    status="$(curl -s -o /dev/null -w '%{http_code}' \
        --resolve test.local:18086:127.0.0.1 \
        "http://test.local:18086/anything" 2>/dev/null)" || status="000"

    if [ "${status}" = "502" ]; then
        pass "Empty static dir causes proxy attempt (502 bad gateway)"
    else
        fail "Expected HTTP 502 (proxy attempt), got ${status}"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-E7: Admin API unreachable during reload retries next cycle
# Requirement: 01-REQ-6.E1
# -----------------------------------------------------------------------
test_ts01_e7_admin_api_unreachable_retry() {
    run_test "TS-01-E7: Admin API unreachable during reload retries next cycle"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "e7")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites"

    cat > "${tmpdir}/sites/test.local.caddy" <<'CADDY'
http://test.local {
    respond "E7 TEST" 200
}
CADDY

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -e RELOAD_INTERVAL=5 \
        -p 18097:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2

    # Temporarily stop Caddy inside the container
    caddy_pid="$(podman exec "${cname}" pidof httpsvc 2>/dev/null)" || caddy_pid=""
    if [ -n "${caddy_pid}" ]; then
        podman exec "${cname}" kill -STOP "${caddy_pid}" 2>/dev/null || true
    fi

    # Trigger a config change
    cat > "${tmpdir}/sites/new.local.caddy" <<'CADDY'
http://new.local {
    respond "NEW AFTER RETRY" 200
}
CADDY

    # Wait for a reload attempt while Caddy is stopped
    sleep 10

    logs="$(podman logs "${cname}" 2>&1)"
    if printf '%s' "${logs}" | grep -qiE "(error|failed)"; then
        pass "Entrypoint logged a reload error when admin API unreachable"
    else
        fail "No error logged when admin API was unreachable"
    fi

    # Resume Caddy
    if [ -n "${caddy_pid}" ]; then
        podman exec "${cname}" kill -CONT "${caddy_pid}" 2>/dev/null || true
    fi

    # Wait for the next reload cycle to succeed after SIGCONT
    # The entrypoint should retry on the next cycle and apply the new config
    max_wait=15
    elapsed=0
    retry_succeeded=false
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        body="$(curl -s --resolve "new.local:18097:127.0.0.1" \
            "http://new.local:18097/" 2>/dev/null)" || body=""
        if printf '%s' "${body}" | grep -qF "NEW AFTER RETRY"; then
            retry_succeeded=true
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "${retry_succeeded}" = "true" ]; then
        pass "Subsequent reload cycle succeeded after admin API recovered (${elapsed}s)"
    else
        fail "New site not live after admin API recovered (waited ${max_wait}s)"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# =====================================================================
# Property Tests (TS-01-P1 through TS-01-P7)
# =====================================================================

# -----------------------------------------------------------------------
# TS-01-P1: Import Completeness
# Property 1: Every site snippet is included after reload
# Validates: 01-REQ-1.1, 01-REQ-1.2, 01-REQ-1.3
# -----------------------------------------------------------------------
test_ts01_p1_import_completeness() {
    run_test "TS-01-P1: Import Completeness — every snippet is loaded"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "p1")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/sitedata"

    # Generate 3 distinct site snippets
    for domain in site-a.local site-b.local site-c.local; do
        mkdir -p "${tmpdir}/sitedata/${domain}/static" "${tmpdir}/sitedata/${domain}/logs"
        cat > "${tmpdir}/sites/${domain}.caddy" <<CADDY
http://${domain} {
    root * /sites/${domain}/static
    respond "SITE: ${domain}" 200
}
CADDY
    done

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/sitedata:/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -p 18087:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2
    local_fail=0

    for domain in site-a.local site-b.local site-c.local; do
        body="$(curl -s --resolve "${domain}:18087:127.0.0.1" \
            "http://${domain}:18087/" 2>/dev/null)" || body=""
        if printf '%s' "${body}" | grep -qF "SITE: ${domain}"; then
            pass "Domain ${domain} is served"
        else
            fail "Domain ${domain} not responding (got: ${body})"
            local_fail=1
        fi
    done

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
    return ${local_fail}
}

# -----------------------------------------------------------------------
# TS-01-P2: Certificate Persistence
# Property 2: Certificates survive container restarts
# Validates: 01-REQ-2.1, 01-REQ-2.2
# -----------------------------------------------------------------------
test_ts01_p2_certificate_persistence() {
    run_test "TS-01-P2: Certificate Persistence"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "p2")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/data"

    cat > "${tmpdir}/sites/cert-test.example.com.caddy" <<'CADDY'
cert-test.example.com {
    respond "CERT PERSIST TEST" 200
}
CADDY

    # First run — certificates should be obtained
    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/data:/data:Z" \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start (first run)"
        rm -rf "${tmpdir}"
        return
    }

    sleep 5

    # Record certificate file count before restart
    cert_count_before="$(podman exec "${cname}" find /data -name '*.crt' -o -name '*.key' 2>/dev/null | wc -l)" || cert_count_before="0"

    podman stop "${cname}" >/dev/null 2>&1 || true
    podman rm "${cname}" >/dev/null 2>&1 || true

    # Second run — same data volume, should reuse certs
    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/data:/data:Z" \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start (second run)"
        rm -rf "${tmpdir}"
        return
    }

    sleep 5

    cert_count_after="$(podman exec "${cname}" find /data -name '*.crt' -o -name '*.key' 2>/dev/null | wc -l)" || cert_count_after="0"
    # cert counts should match (no new certs obtained)
    if [ "${cert_count_before}" = "${cert_count_after}" ]; then
        pass "Certificate file count unchanged after restart (${cert_count_before})"
    else
        fail "Certificate file count changed: ${cert_count_before} -> ${cert_count_after}"
    fi

    logs2="$(podman logs "${cname}" 2>&1)"
    if printf '%s' "${logs2}" | grep -qiE "obtaining.*certificate"; then
        fail "Second start re-obtained certificates (should reuse)"
    else
        pass "Second start did not re-obtain certificates"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-P3: Log Isolation
# Property 3: Requests to site A produce logs only in site A's directory
# Validates: 01-REQ-3.1
# -----------------------------------------------------------------------
test_ts01_p3_log_isolation() {
    run_test "TS-01-P3: Log Isolation"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "p3")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites"

    for domain in alpha.local beta.local; do
        mkdir -p "${tmpdir}/sitedata/${domain}/static" "${tmpdir}/sitedata/${domain}/logs"
        cat > "${tmpdir}/sites/${domain}.caddy" <<CADDY
http://${domain} {
    root * /sites/${domain}/static
    log {
        output file /sites/${domain}/logs/access.log
        format json
    }
    respond "SITE: ${domain}" 200
}
CADDY
    done

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/sitedata:/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -p 18088:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2

    # Send request only to alpha.local
    curl -s --resolve "alpha.local:18088:127.0.0.1" \
        "http://alpha.local:18088/test-isolation" >/dev/null 2>&1 || true

    sleep 2

    log_alpha="$(podman exec "${cname}" cat /sites/alpha.local/logs/access.log 2>/dev/null)" || log_alpha=""
    log_beta="$(podman exec "${cname}" cat /sites/beta.local/logs/access.log 2>/dev/null)" || log_beta=""

    local_fail=0

    if printf '%s' "${log_alpha}" | grep -qF "test-isolation"; then
        pass "Request logged in alpha.local's access log"
    else
        fail "Request NOT found in alpha.local's access log"
        local_fail=1
    fi

    if printf '%s' "${log_beta}" | grep -qF "test-isolation"; then
        fail "Request leaked into beta.local's access log"
        local_fail=1
    else
        pass "Request NOT in beta.local's access log (isolation confirmed)"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
    return ${local_fail}
}

# -----------------------------------------------------------------------
# TS-01-P4: Static-Then-Proxy Precedence
# Property 4: Static files take precedence over reverse proxy
# Validates: 01-REQ-4.1, 01-REQ-4.2
# -----------------------------------------------------------------------
test_ts01_p4_static_then_proxy() {
    run_test "TS-01-P4: Static-Then-Proxy Precedence"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "p4")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/sitedata/static-test.local/static" "${tmpdir}/sitedata/static-test.local/logs"

    # Create a static file
    printf 'STATIC:index.html' > "${tmpdir}/sitedata/static-test.local/static/index.html"

    cat > "${tmpdir}/sites/static-test.local.caddy" <<'CADDY'
http://static-test.local {
    root * /sites/static-test.local/static
    log {
        output file /sites/static-test.local/logs/access.log
        format json
    }

    @static file
    handle @static {
        file_server
    }

    handle {
        reverse_proxy host.containers.internal:19877
    }
}
CADDY

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/sitedata:/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -p 18089:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2

    # Request the static file
    body="$(curl -s --resolve "static-test.local:18089:127.0.0.1" \
        "http://static-test.local:18089/index.html" 2>/dev/null)" || body=""

    if printf '%s' "${body}" | grep -qF "STATIC:index.html"; then
        pass "Static file served directly (precedence over proxy)"
    else
        fail "Static file not served directly (got: ${body})"
    fi

    # Request a non-static path — should attempt proxy (502 if no upstream)
    status="$(curl -s -o /dev/null -w '%{http_code}' \
        --resolve "static-test.local:18089:127.0.0.1" \
        "http://static-test.local:18089/api/data" 2>/dev/null)" || status="000"

    if [ "${status}" = "502" ]; then
        pass "Non-static path falls through to proxy (502 without upstream)"
    else
        fail "Non-static path did not reach proxy, got HTTP ${status}"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-P5: Reload Timeliness
# Property 5: Config changes trigger reload within poll interval
# Validates: 01-REQ-5.1, 01-REQ-5.2, 01-REQ-5.3
# -----------------------------------------------------------------------
test_ts01_p5_reload_timeliness() {
    run_test "TS-01-P5: Reload Timeliness"

    require_podman || return 0
    require_image || return 0

    # Test with interval=10 only (60 would violate REQ-5.1 max of 30)
    interval=10
    cname="$(container_name "p5")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites"

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -e RELOAD_INTERVAL="${interval}" \
        -p 18090:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2

    # Add a new site snippet
    cat > "${tmpdir}/sites/reload-test.local.caddy" <<'CADDY'
http://reload-test.local {
    respond "RELOAD OK" 200
}
CADDY

    # Wait up to interval + 5 seconds for the site to become live
    max_wait=$((interval + 5))
    elapsed=0
    site_live=false
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        body="$(curl -s --resolve "reload-test.local:18090:127.0.0.1" \
            "http://reload-test.local:18090/" 2>/dev/null)" || body=""
        if printf '%s' "${body}" | grep -qF "RELOAD OK"; then
            site_live=true
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "${site_live}" = "true" ]; then
        pass "New site became live within ${elapsed}s (interval=${interval})"
    else
        fail "New site not live after ${max_wait}s (interval=${interval})"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-P6: Reload Failure Isolation
# Property 6: Failed reloads do not affect running config
# Validates: 01-REQ-1.E2, 01-REQ-5.E1
# -----------------------------------------------------------------------
test_ts01_p6_reload_failure_isolation() {
    run_test "TS-01-P6: Reload Failure Isolation"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "p6")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/sitedata"

    # Create 2 valid sites
    for domain in ok-a.local ok-b.local; do
        mkdir -p "${tmpdir}/sitedata/${domain}/static" "${tmpdir}/sitedata/${domain}/logs"
        cat > "${tmpdir}/sites/${domain}.caddy" <<CADDY
http://${domain} {
    root * /sites/${domain}/static
    respond "SITE: ${domain}" 200
}
CADDY
    done

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/sitedata:/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -e RELOAD_INTERVAL=5 \
        -p 18091:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2

    # Verify both sites are live
    for domain in ok-a.local ok-b.local; do
        body="$(curl -s --resolve "${domain}:18091:127.0.0.1" \
            "http://${domain}:18091/" 2>/dev/null)" || body=""
        if ! printf '%s' "${body}" | grep -qF "SITE: ${domain}"; then
            fail "Site ${domain} not live before invalid reload"
            cleanup_container "${cname}"
            rm -rf "${tmpdir}"
            return
        fi
    done

    # Add an invalid snippet to trigger a failed reload
    printf '{{{{invalid' > "${tmpdir}/sites/broken.caddy"

    # Wait for reload cycle
    sleep 10

    # Verify both sites are still live after failed reload
    local_fail=0
    for domain in ok-a.local ok-b.local; do
        body="$(curl -s --resolve "${domain}:18091:127.0.0.1" \
            "http://${domain}:18091/" 2>/dev/null)" || body=""
        if printf '%s' "${body}" | grep -qF "SITE: ${domain}"; then
            pass "Site ${domain} still live after failed reload"
        else
            fail "Site ${domain} broken after failed reload"
            local_fail=1
        fi
    done

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
    return ${local_fail}
}

# -----------------------------------------------------------------------
# TS-01-P7: Admin API Confinement
# Property 7: Admin API not reachable from outside the container
# Validates: 01-REQ-6.1, 01-REQ-6.2
# -----------------------------------------------------------------------
test_ts01_p7_admin_api_confinement() {
    run_test "TS-01-P7: Admin API Confinement"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "p7")"
    cleanup_container "${cname}"

    podman run -d --name "${cname}" \
        -e HTTPSVC_LISTEN="http://" \
        -p 18092:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        return
    fi

    sleep 2

    # Port 2019 should NOT be mapped/exposed externally
    # Attempt to connect from host — should fail
    status="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 2 \
        "http://localhost:2019/config/" 2>/dev/null)" || status="000"

    if [ "${status}" = "000" ]; then
        pass "Admin API not reachable from host (connection refused/timeout)"
    else
        fail "Admin API reachable from host (HTTP ${status})"
    fi

    # Admin API should be reachable from INSIDE the container
    internal_status="$(podman exec "${cname}" \
        sh -c 'curl -s -o /dev/null -w "%{http_code}" http://localhost:2019/config/ 2>/dev/null')" || internal_status="000"

    if [ "${internal_status}" = "200" ]; then
        pass "Admin API reachable internally on localhost:2019"
    else
        fail "Admin API NOT reachable internally (HTTP ${internal_status})"
    fi

    cleanup_container "${cname}"
}

# =====================================================================
# Smoke Tests (TS-01-SMOKE-1 through TS-01-SMOKE-4)
# =====================================================================

# -----------------------------------------------------------------------
# TS-01-SMOKE-1: Full startup with site configs
# Execution Path 1 from design.md
# -----------------------------------------------------------------------
test_ts01_smoke1_full_startup() {
    run_test "TS-01-SMOKE-1: Full startup with site configs"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "smoke1")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/sitedata/smoke.local/static" "${tmpdir}/sitedata/smoke.local/logs" "${tmpdir}/data"

    # Create a static index page
    printf 'SMOKE TEST PAGE' > "${tmpdir}/sitedata/smoke.local/static/index.html"

    cat > "${tmpdir}/sites/smoke.local.caddy" <<'CADDY'
http://smoke.local {
    root * /sites/smoke.local/static
    log {
        output file /sites/smoke.local/logs/access.log
        format json
    }

    @static file
    handle @static {
        file_server
    }

    handle {
        respond "NO UPSTREAM" 502
    }
}
CADDY

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/sitedata:/sites:Z" \
        -v "${tmpdir}/data:/data:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -p 18093:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container not running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2
    local_fail=0

    # Check HTTP response
    body="$(curl -s --resolve "smoke.local:18093:127.0.0.1" \
        "http://smoke.local:18093/index.html" 2>/dev/null)" || body=""
    if printf '%s' "${body}" | grep -qF "SMOKE TEST PAGE"; then
        pass "Static file served correctly"
    else
        fail "Static file not served (got: ${body})"
        local_fail=1
    fi

    # Check log file
    sleep 1
    log_content="$(podman exec "${cname}" cat /sites/smoke.local/logs/access.log 2>/dev/null)" || log_content=""
    if [ -n "${log_content}" ]; then
        pass "Access log exists and has content"
    else
        fail "Access log empty or missing"
        local_fail=1
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
    return ${local_fail}
}

# -----------------------------------------------------------------------
# TS-01-SMOKE-2: Hot-reload adds new site
# Execution Path 2 from design.md
# -----------------------------------------------------------------------
test_ts01_smoke2_hot_reload() {
    run_test "TS-01-SMOKE-2: Hot-reload adds new site"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "smoke2")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites"

    # Start with one site
    cat > "${tmpdir}/sites/initial.local.caddy" <<'CADDY'
http://initial.local {
    respond "INITIAL SITE" 200
}
CADDY

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -e RELOAD_INTERVAL=5 \
        -p 18094:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2

    # Verify initial site
    body="$(curl -s --resolve "initial.local:18094:127.0.0.1" \
        "http://initial.local:18094/" 2>/dev/null)" || body=""
    if ! printf '%s' "${body}" | grep -qF "INITIAL SITE"; then
        fail "Initial site not working"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    # Add a second site
    cat > "${tmpdir}/sites/added.local.caddy" <<'CADDY'
http://added.local {
    respond "ADDED SITE" 200
}
CADDY

    # Wait for reload (interval=5, so allow up to 10s)
    max_wait=15
    elapsed=0
    site_live=false
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        body="$(curl -s --resolve "added.local:18094:127.0.0.1" \
            "http://added.local:18094/" 2>/dev/null)" || body=""
        if printf '%s' "${body}" | grep -qF "ADDED SITE"; then
            site_live=true
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "${site_live}" = "true" ]; then
        pass "Hot-reload picked up new site within ${elapsed}s"
    else
        fail "New site not live after ${max_wait}s"
    fi

    # Check that reload was logged
    logs="$(podman logs "${cname}" 2>&1)"
    if printf '%s' "${logs}" | grep -qiF "reload"; then
        pass "Reload logged in container output"
    else
        fail "No reload message in container logs"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-SMOKE-3: Static file served, proxy fallback for missing files
# Execution Path 3 from design.md
# -----------------------------------------------------------------------
test_ts01_smoke3_static_and_proxy() {
    run_test "TS-01-SMOKE-3: Static file served, proxy fallback for missing files"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "smoke3")"
    cleanup_container "${cname}"

    tmpdir="$(mktemp -d)"
    mkdir -p "${tmpdir}/sites" "${tmpdir}/sitedata/proxy-test.local/static" "${tmpdir}/sitedata/proxy-test.local/logs"

    # Create a static file
    printf 'STATIC PAGE' > "${tmpdir}/sitedata/proxy-test.local/static/index.html"

    cat > "${tmpdir}/sites/proxy-test.local.caddy" <<'CADDY'
http://proxy-test.local {
    root * /sites/proxy-test.local/static
    log {
        output file /sites/proxy-test.local/logs/access.log
        format json
    }

    @static file
    handle @static {
        file_server
    }

    handle {
        reverse_proxy host.containers.internal:19878
    }
}
CADDY

    podman run -d --name "${cname}" \
        -v "${tmpdir}/sites:/etc/caddy/sites:Z" \
        -v "${tmpdir}/sitedata:/sites:Z" \
        -e HTTPSVC_LISTEN="http://" \
        -p 18095:80 \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        rm -rf "${tmpdir}"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        rm -rf "${tmpdir}"
        return
    fi

    sleep 2

    # Static file request
    body="$(curl -s --resolve "proxy-test.local:18095:127.0.0.1" \
        "http://proxy-test.local:18095/index.html" 2>/dev/null)" || body=""
    if printf '%s' "${body}" | grep -qF "STATIC PAGE"; then
        pass "Static file served correctly"
    else
        fail "Static file not served (got: ${body})"
    fi

    # Non-static path — should attempt proxy (502 without upstream)
    status="$(curl -s -o /dev/null -w '%{http_code}' \
        --resolve "proxy-test.local:18095:127.0.0.1" \
        "http://proxy-test.local:18095/api/data" 2>/dev/null)" || status="000"

    if [ "${status}" = "502" ]; then
        pass "Non-static path falls through to proxy (502)"
    else
        fail "Expected HTTP 502 for proxy fallback, got ${status}"
    fi

    cleanup_container "${cname}"
    rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------
# TS-01-SMOKE-4: Graceful shutdown
# Execution Path 4 from design.md
# -----------------------------------------------------------------------
test_ts01_smoke4_graceful_shutdown() {
    run_test "TS-01-SMOKE-4: Graceful shutdown"

    require_podman || return 0
    require_image || return 0

    cname="$(container_name "smoke4")"
    cleanup_container "${cname}"

    podman run -d --name "${cname}" \
        -e HTTPSVC_LISTEN="http://" \
        "${IMAGE}" >/dev/null 2>&1 || {
        fail "Container failed to start"
        return
    }

    if ! wait_running "${cname}"; then
        fail "Container did not stay running"
        cleanup_container "${cname}"
        return
    fi

    sleep 2

    # Send SIGTERM via podman stop (default behavior)
    podman stop --time 10 "${cname}" >/dev/null 2>&1
    exit_code="$(podman inspect --format '{{.State.ExitCode}}' "${cname}" 2>/dev/null)" || exit_code="unknown"

    if [ "${exit_code}" = "0" ]; then
        pass "Container exited cleanly with code 0"
    else
        fail "Container exited with code ${exit_code} (expected 0)"
    fi

    # Check logs for shutdown errors
    logs="$(podman logs "${cname}" 2>&1)"
    if printf '%s' "${logs}" | grep -qiE "(panic|fatal|segfault)"; then
        fail "Shutdown logs contain error/panic"
    else
        pass "No fatal errors in shutdown logs"
    fi

    podman rm "${cname}" >/dev/null 2>&1 || true
}

# =====================================================================
# Main
# =====================================================================

main() {
    printf "=== Integration, Edge Case, Property & Smoke Tests ===\n\n"

    # Edge case tests
    printf "--- Edge Case Tests ---\n"
    test_ts01_e1_empty_sites_dir
    test_ts01_e2_invalid_snippet_reload
    test_ts01_e3_invalid_reload_interval || true
    test_ts01_e4_empty_data_volume
    test_ts01_e5_no_sites_volume
    test_ts01_e6_empty_static_proxies
    test_ts01_e7_admin_api_unreachable_retry

    # Property tests
    printf "\n--- Property Tests ---\n"
    test_ts01_p1_import_completeness || true
    test_ts01_p2_certificate_persistence
    test_ts01_p3_log_isolation || true
    test_ts01_p4_static_then_proxy
    test_ts01_p5_reload_timeliness
    test_ts01_p6_reload_failure_isolation || true
    test_ts01_p7_admin_api_confinement

    # Smoke tests
    printf "\n--- Smoke Tests ---\n"
    test_ts01_smoke1_full_startup || true
    test_ts01_smoke2_hot_reload
    test_ts01_smoke3_static_and_proxy
    test_ts01_smoke4_graceful_shutdown

    printf "\n=== Results: %d tests, %d passed, %d failed, %d skipped ===\n" \
        "${TESTS_RUN}" "${TESTS_PASSED}" "${TESTS_FAILED}" "${TESTS_SKIPPED}"

    if [ "${TESTS_FAILED}" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
