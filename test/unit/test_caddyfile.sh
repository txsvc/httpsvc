#!/bin/bash
# test/unit/test_caddyfile.sh — Unit tests for Caddyfile and related config files.
# Tests: TS-01-1 through TS-01-8
#
# These tests assert file content of containers/httpsvc/Caddyfile, containers/httpsvc/sites/example.com.caddy,
# and containers/httpsvc/Containerfile. They are expected to FAIL until the implementation is done.
set -eu

# --- test harness ---
TESTS_RUN=0
TESTS_FAILED=0
TESTS_PASSED=0

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CADDYFILE="${REPO_ROOT}/containers/httpsvc/Caddyfile"
EXAMPLE_SNIPPET="${REPO_ROOT}/containers/httpsvc/sites/example.com.caddy"
CONTAINERFILE="${REPO_ROOT}/containers/httpsvc/Containerfile"

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "  PASS: %s\n" "$1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  FAIL: %s\n" "$1"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf "TEST: %s\n" "$1"
}

# -----------------------------------------------------------------------
# TS-01-1: Main Caddyfile imports site snippets
# Requirement: 01-REQ-1.3
# -----------------------------------------------------------------------
test_ts01_1_caddyfile_imports_site_snippets() {
    run_test "TS-01-1: Main Caddyfile imports site snippets"

    if [ ! -f "${CADDYFILE}" ]; then
        fail "Caddyfile does not exist at ${CADDYFILE}"
        return
    fi

    if grep -qF "import /etc/caddy/sites/*.caddy" "${CADDYFILE}"; then
        pass "Caddyfile contains import glob for site snippets"
    else
        fail "Caddyfile does not contain 'import /etc/caddy/sites/*.caddy'"
    fi
}

# -----------------------------------------------------------------------
# TS-01-2: Main Caddyfile configures admin API on localhost
# Requirement: 01-REQ-6.1
# -----------------------------------------------------------------------
test_ts01_2_caddyfile_admin_localhost() {
    run_test "TS-01-2: Main Caddyfile configures admin API on localhost"

    if [ ! -f "${CADDYFILE}" ]; then
        fail "Caddyfile does not exist at ${CADDYFILE}"
        return
    fi

    if grep -qF "admin localhost:2019" "${CADDYFILE}"; then
        pass "Caddyfile configures admin API on localhost:2019"
    else
        fail "Caddyfile does not contain 'admin localhost:2019'"
    fi
}

# -----------------------------------------------------------------------
# TS-01-3: Caddyfile validates successfully with example snippet
# Requirement: 01-REQ-1.1
# -----------------------------------------------------------------------
test_ts01_3_caddyfile_validates() {
    run_test "TS-01-3: Caddyfile validates successfully with example snippet"

    if [ ! -f "${EXAMPLE_SNIPPET}" ]; then
        fail "Example snippet does not exist at ${EXAMPLE_SNIPPET}"
        return
    fi

    # Create a temporary directory structure that mirrors the container layout.
    # validate provisions resources (e.g. log writers), so all referenced
    # paths must exist locally.
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' EXIT

    mkdir -p "${tmpdir}/sites"

    # Copy each snippet, rewriting /sites/<domain>/ paths to the temp dir
    for f in "${REPO_ROOT}"/containers/httpsvc/sites/*.caddy; do
        domain="$(basename "$f" .caddy)"
        mkdir -p "${tmpdir}/sitedata/${domain}/logs" "${tmpdir}/sitedata/${domain}/static"
        sed "s|/sites/${domain}/|${tmpdir}/sitedata/${domain}/|g" \
            "$f" > "${tmpdir}/sites/$(basename "$f")"
    done

    # Replace the production import path with the local temp path
    sed "s|import /etc/caddy/sites/\\*\\.caddy|import ${tmpdir}/sites/*.caddy|" \
        "${CADDYFILE}" > "${tmpdir}/Caddyfile"

    httpsvc_bin="${REPO_ROOT}/bin/httpsvc"
    if [ ! -x "${httpsvc_bin}" ]; then
        fail "httpsvc binary not found at ${httpsvc_bin} (run 'make build' first)"
        return
    fi

    if "${httpsvc_bin}" validate --config "${tmpdir}/Caddyfile" --adapter caddyfile 2>/dev/null; then
        pass "Caddyfile validates successfully with example snippet"
    else
        fail "Caddyfile validation failed"
    fi
}

# -----------------------------------------------------------------------
# TS-01-4: Example site snippet has correct log output path
# Requirement: 01-REQ-3.1
# -----------------------------------------------------------------------
test_ts01_4_snippet_log_path() {
    run_test "TS-01-4: Example site snippet has correct log output path"

    if [ ! -f "${EXAMPLE_SNIPPET}" ]; then
        fail "Example snippet does not exist at ${EXAMPLE_SNIPPET}"
        return
    fi

    local_fail=0

    if grep -qF "output file /sites/example.com/logs/access.log" "${EXAMPLE_SNIPPET}"; then
        pass "Snippet contains correct log output path"
    else
        fail "Snippet does not contain 'output file /sites/example.com/logs/access.log'"
        local_fail=1
    fi

    if grep -qF "format json" "${EXAMPLE_SNIPPET}"; then
        pass "Snippet contains 'format json'"
    else
        fail "Snippet does not contain 'format json'"
        local_fail=1
    fi

    return ${local_fail}
}

# -----------------------------------------------------------------------
# TS-01-5: Example site snippet has correct static root
# Requirement: 01-REQ-4.3
# -----------------------------------------------------------------------
test_ts01_5_snippet_static_root() {
    run_test "TS-01-5: Example site snippet has correct static root"

    if [ ! -f "${EXAMPLE_SNIPPET}" ]; then
        fail "Example snippet does not exist at ${EXAMPLE_SNIPPET}"
        return
    fi

    if grep -qF "root * /sites/example.com/static" "${EXAMPLE_SNIPPET}"; then
        pass "Snippet sets root to /sites/example.com/static"
    else
        fail "Snippet does not contain 'root * /sites/example.com/static'"
    fi
}

# -----------------------------------------------------------------------
# TS-01-6: Example site snippet uses file_server with static matcher
# Requirement: 01-REQ-4.1, 01-REQ-4.2
# -----------------------------------------------------------------------
test_ts01_6_snippet_file_server_and_proxy() {
    run_test "TS-01-6: Example site snippet uses file_server with static matcher"

    if [ ! -f "${EXAMPLE_SNIPPET}" ]; then
        fail "Example snippet does not exist at ${EXAMPLE_SNIPPET}"
        return
    fi

    local_fail=0

    if grep -qF "@static file" "${EXAMPLE_SNIPPET}"; then
        pass "Snippet contains '@static file' matcher"
    else
        fail "Snippet does not contain '@static file' matcher"
        local_fail=1
    fi

    if grep -qF "file_server" "${EXAMPLE_SNIPPET}"; then
        pass "Snippet contains 'file_server'"
    else
        fail "Snippet does not contain 'file_server'"
        local_fail=1
    fi

    if grep -qF "reverse_proxy" "${EXAMPLE_SNIPPET}"; then
        pass "Snippet contains 'reverse_proxy'"
    else
        fail "Snippet does not contain 'reverse_proxy'"
        local_fail=1
    fi

    return ${local_fail}
}

# -----------------------------------------------------------------------
# TS-01-7: Containerfile does not expose port 2019
# Requirement: 01-REQ-6.2
# -----------------------------------------------------------------------
test_ts01_7_containerfile_no_expose_2019() {
    run_test "TS-01-7: Containerfile does not expose port 2019"

    if [ ! -f "${CONTAINERFILE}" ]; then
        fail "Containerfile does not exist at ${CONTAINERFILE}"
        return
    fi

    if grep -qi "EXPOSE.*2019" "${CONTAINERFILE}"; then
        fail "Containerfile exposes port 2019 (admin API should be localhost-only)"
    else
        pass "Containerfile does not expose port 2019"
    fi
}

# -----------------------------------------------------------------------
# TS-01-8: Containerfile declares /sites volume
# Requirement: 01-REQ-3.3
# -----------------------------------------------------------------------
test_ts01_8_containerfile_sites_volume() {
    run_test "TS-01-8: Containerfile declares /sites volume"

    if [ ! -f "${CONTAINERFILE}" ]; then
        fail "Containerfile does not exist at ${CONTAINERFILE}"
        return
    fi

    if grep -q "VOLUME.*/sites" "${CONTAINERFILE}"; then
        pass "Containerfile declares /sites volume"
    else
        fail "Containerfile does not declare a /sites volume"
    fi
}

# --- run all tests ---
main() {
    printf "=== Caddyfile & Config Unit Tests ===\n\n"

    test_ts01_1_caddyfile_imports_site_snippets
    test_ts01_2_caddyfile_admin_localhost
    test_ts01_3_caddyfile_validates
    test_ts01_4_snippet_log_path || true
    test_ts01_5_snippet_static_root
    test_ts01_6_snippet_file_server_and_proxy || true
    test_ts01_7_containerfile_no_expose_2019
    test_ts01_8_containerfile_sites_volume

    printf "\n=== Results: %d tests, %d passed, %d failed ===\n" \
        "${TESTS_RUN}" "${TESTS_PASSED}" "${TESTS_FAILED}"

    if [ "${TESTS_FAILED}" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
