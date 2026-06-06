#!/bin/bash
# test/unit/test_entrypoint.sh — Unit tests for the entrypoint script (containers/httpsvc/run).
# Tests: TS-01-9, TS-01-10
#
# These tests assert content of containers/httpsvc/run to verify hot-reload logic.
# They are expected to FAIL until the entrypoint is rewritten.
set -eu

# --- test harness ---
TESTS_RUN=0
TESTS_FAILED=0
TESTS_PASSED=0

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTRYPOINT="${REPO_ROOT}/containers/httpsvc/run"

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
# TS-01-9: Entrypoint uses RELOAD_INTERVAL with default 30
# Requirement: 01-REQ-5.3
# -----------------------------------------------------------------------
test_ts01_9_entrypoint_reload_interval() {
    run_test "TS-01-9: Entrypoint uses RELOAD_INTERVAL with default 30"

    if [ ! -f "${ENTRYPOINT}" ]; then
        fail "Entrypoint script does not exist at ${ENTRYPOINT}"
        return
    fi

    local_fail=0

    if grep -qF "RELOAD_INTERVAL" "${ENTRYPOINT}"; then
        pass "Entrypoint references RELOAD_INTERVAL"
    else
        fail "Entrypoint does not reference RELOAD_INTERVAL"
        local_fail=1
    fi

    # Check for a default value of 30, matching patterns like:
    #   RELOAD_INTERVAL=${RELOAD_INTERVAL:-30}
    #   ${RELOAD_INTERVAL:-30}
    #   : "${RELOAD_INTERVAL:=30}"
    if grep -qE '(RELOAD_INTERVAL[^0-9]*30|:-30\}|:=30\})' "${ENTRYPOINT}"; then
        pass "Entrypoint defaults RELOAD_INTERVAL to 30"
    else
        fail "Entrypoint does not default RELOAD_INTERVAL to 30"
        local_fail=1
    fi

    return ${local_fail}
}

# -----------------------------------------------------------------------
# TS-01-10: Entrypoint logs reload attempts
# Requirement: 01-REQ-5.2
# -----------------------------------------------------------------------
test_ts01_10_entrypoint_logs_reload() {
    run_test "TS-01-10: Entrypoint logs reload attempts"

    if [ ! -f "${ENTRYPOINT}" ]; then
        fail "Entrypoint script does not exist at ${ENTRYPOINT}"
        return
    fi

    # The entrypoint should contain both a reload command and log output
    # around it. We check for:
    #   1. A reload command (httpsvc reload)
    #   2. Logging statements (echo/printf) near the reload
    local_fail=0

    if grep -qE '(httpsvc|caddy).*reload' "${ENTRYPOINT}"; then
        pass "Entrypoint contains a reload command"
    else
        fail "Entrypoint does not contain a reload command (httpsvc reload or caddy reload)"
        local_fail=1
    fi

    if grep -qE '(echo|printf|log).*[Rr]eload' "${ENTRYPOINT}"; then
        pass "Entrypoint logs reload events"
    else
        fail "Entrypoint does not log reload events"
        local_fail=1
    fi

    return ${local_fail}
}

# --- run all tests ---
main() {
    printf "=== Entrypoint Unit Tests ===\n\n"

    test_ts01_9_entrypoint_reload_interval || true
    test_ts01_10_entrypoint_logs_reload || true

    printf "\n=== Results: %d tests, %d passed, %d failed ===\n" \
        "${TESTS_RUN}" "${TESTS_PASSED}" "${TESTS_FAILED}"

    if [ "${TESTS_FAILED}" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
