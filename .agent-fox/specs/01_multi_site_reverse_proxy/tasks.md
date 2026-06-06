# Implementation Plan: Multi-Site Reverse Proxy

<!-- AGENT INSTRUCTIONS
- Implement exactly ONE top-level task group per session
- Task group 1 writes failing tests from test_spec.md — all subsequent groups
  implement code to make those tests pass
- Follow the git-flow: feature branch from develop -> implement -> test -> merge to develop
- Update checkbox states as you go: [-] in progress, [x] complete
-->

## Overview

This spec is configuration-driven: no custom Go modules are needed. The
implementation modifies the Caddyfile, entrypoint script, Containerfile, and
Makefile. Tests are shell-based (BATS and direct assertions) since the work is
primarily in config files and shell scripts.

Task groups are ordered so that test infrastructure comes first (group 1),
then the Caddyfile and site snippet template (group 2), the entrypoint script
with hot-reload (group 3), the container and Makefile updates (group 4), and
finally wiring verification (group 5).

## Test Commands

- Config validation: `bin/httpsvc validate --config deploy/Caddyfile --adapter caddyfile`
- Unit tests (shell): `make test-unit`
- Integration tests: `make test-integration`
- All tests: `make test-all`
- Lint (shell): `shellcheck deploy/run`

## Tasks

- [ ] 1. Write failing spec tests
  - [ ] 1.1 Create test directory structure
    - Create `test/` directory with subdirectories `unit/` and `integration/`.
    - Add a `test/unit/test_caddyfile.sh` for Caddyfile content assertions (TS-01-1 through TS-01-8).
    - Add a `test/unit/test_entrypoint.sh` for entrypoint script assertions (TS-01-9, TS-01-10).
    - Add a `test/integration/test_container.sh` for container-based tests.
    - _Test Spec: TS-01-1 through TS-01-10_

  - [ ] 1.2 Implement unit test assertions
    - Write shell functions that grep/assert file content for each TS-01-N entry.
    - Tests MUST fail against current file content (pre-implementation).
    - _Test Spec: TS-01-1 through TS-01-10_

  - [ ] 1.3 Implement edge case test stubs
    - Write integration test functions for TS-01-E1, TS-01-E2, TS-01-E3,
      TS-01-E4, TS-01-E5, TS-01-E6, TS-01-E7.
    - Tests should be structured but expected to fail (container not yet updated).
    - _Test Spec: TS-01-E1 through TS-01-E7_

  - [ ] 1.4 Implement property test stubs
    - Write test functions for TS-01-P1, TS-01-P2, TS-01-P3, TS-01-P4,
      TS-01-P5, TS-01-P6, TS-01-P7.
    - Tests should be structured but expected to fail.
    - _Test Spec: TS-01-P1 through TS-01-P7_

  - [ ] 1.5 Implement integration smoke test stubs
    - Write test functions for TS-01-SMOKE-1 through TS-01-SMOKE-4.
    - Tests should be structured but expected to fail.
    - _Test Spec: TS-01-SMOKE-1 through TS-01-SMOKE-4_

  - [ ] 1.6 Add test targets to Makefile
    - Add `test-unit`, `test-integration`, and `test-all` targets.
    - _Requirements: all_

  - [ ] 1.V Verify task group 1
    - [ ] All test files exist and are syntactically valid (`bash -n test/**/*.sh`)
    - [ ] All unit tests FAIL (red) — no implementation yet
    - [ ] `shellcheck test/**/*.sh` passes (no shell lint warnings)

- [x] 2. Main Caddyfile and site snippet template
  - [x] 2.1 Rewrite deploy/Caddyfile
    - Add `admin localhost:2019` to global options block.
    - Replace the static `respond` site block with `import /etc/caddy/sites/*.caddy`.
    - Keep ACME email env var.
    - _Requirements: 1.3, 6.1_

  - [x] 2.2 Create deploy/sites/ directory with example snippet
    - Create `deploy/sites/example.com.caddy` with:
      - `root * /sites/example.com/static`
      - `log` block outputting JSON to `/sites/example.com/logs/access.log`
      - `@static file` matcher with `handle @static { file_server }`
      - Fallback `handle { reverse_proxy localhost:8080 }`
    - _Requirements: 3.1, 4.1, 4.2, 4.3_

  - [x] 2.3 Validate Caddyfile locally
    - Run `bin/httpsvc validate` against the new Caddyfile + example snippet
      (adjusting import paths for local validation).
    - _Requirements: 1.1_

  - [x] 2.V Verify task group 2
    - [x] TS-01-1 (import glob) passes
    - [x] TS-01-2 (admin localhost) passes
    - [x] TS-01-3 (validate) passes
    - [x] TS-01-4 (log path) passes
    - [x] TS-01-5 (static root) passes
    - [x] TS-01-6 (file_server + proxy) passes
    - [x] `shellcheck deploy/run` still passes
    - [x] Config validates: `bin/httpsvc validate --config deploy/Caddyfile --adapter caddyfile`

- [x] 3. Entrypoint script with hot-reload
  - [x] 3.1 Rewrite deploy/run
    - Start Caddy as background process (not `exec`), capture PID.
    - Set up `trap` for SIGTERM/SIGINT to forward to Caddy PID.
    - Read `RELOAD_INTERVAL` env var, default to 30, validate numeric.
    - Log warning and fall back to 30 if value is invalid.
    - _Requirements: 5.3, 5.E2_

  - [x] 3.2 Implement config change detection loop
    - Record initial state of `/etc/caddy/sites/` directory.
    - Poll every `RELOAD_INTERVAL` seconds using `find` mtime or checksum.
    - On change: run `httpsvc reload --config $CADDYFILE --adapter caddyfile`.
    - Log reload attempt and result (success/failure) to stdout.
    - On reload failure: log error, continue loop.
    - _Requirements: 5.1, 5.2, 5.E1, 6.E1_

  - [x] 3.3 Implement graceful shutdown
    - On SIGTERM/SIGINT: forward signal to Caddy PID, wait for exit.
    - Exit with Caddy's exit code.
    - _Requirements: 5.4 (graceful reload preserves connections)_

  - [x] 3.V Verify task group 3
    - [x] TS-01-9 (RELOAD_INTERVAL default) passes
    - [x] TS-01-10 (reload logging) passes
    - [x] `shellcheck deploy/run` passes with no warnings
    - [x] Requirements 5.1, 5.2, 5.3, 5.E1, 5.E2 acceptance criteria met

- [x] 4. Container and Makefile updates
  - [x] 4.1 Update deploy/Containerfile
    - Remove `EXPOSE 2019` (admin API is localhost-only).
    - Add `VOLUME /sites` for per-site data.
    - Create `/etc/caddy/sites/` directory in the image.
    - Copy `deploy/sites/` contents into `/etc/caddy/sites/` as defaults.
    - Ensure `/sites` base directory is created.
    - _Requirements: 3.3, 6.2_

  - [x] 4.2 Update Makefile run-container target
    - Add volume mounts: `-v caddy-data:/data`, `-v caddy-sites:/sites`.
    - Add bind mount for site configs: `-v ./deploy/sites:/etc/caddy/sites`.
    - Pass `ACME_EMAIL` and `RELOAD_INTERVAL` env vars.
    - _Requirements: 2.3_

  - [x] 4.3 Update Makefile with test targets
    - Ensure `test-unit`, `test-integration`, `test-all` targets are present
      and functional.
    - _Requirements: all_

  - [x] 4.V Verify task group 4
    - [x] TS-01-7 (no EXPOSE 2019) passes
    - [x] TS-01-8 (VOLUME /sites) passes
    - [x] `make image` builds successfully
    - [x] `make run-container` starts with correct volume mounts
    - [x] All unit tests pass: `make test-unit`

- [ ] 5. Wiring verification

  - [ ] 5.1 Trace every execution path from design.md end-to-end
    - For each path (startup, hot-reload, static-then-proxy, graceful shutdown),
      verify the entry point actually calls the next function in the chain.
    - Confirm no function in the chain is a stub that was never replaced.
    - Every path must be live in production code.
    - _Requirements: all_

  - [ ] 5.2 Verify return values propagate correctly
    - For every function in this spec that returns data consumed by a caller,
      confirm the caller receives and uses the return value.
    - In particular: entrypoint's reload command exit code is checked and logged.
    - _Requirements: all_

  - [ ] 5.3 Run the integration smoke tests
    - All `TS-01-SMOKE-*` tests pass using real components.
    - Build image, start container, test HTTP responses, hot-reload, shutdown.
    - _Test Spec: TS-01-SMOKE-1 through TS-01-SMOKE-4_

  - [ ] 5.4 Stub / dead-code audit
    - Search all files touched by this spec for: `return`, `pass`, `# TODO`,
      `# stub`, `NotImplementedError`.
    - Each hit must be justified or replaced.
    - Remove the `respond "Hello World!" 200` placeholder from any config.

  - [ ] 5.5 Cross-spec entry point verification
    - This is the first spec — no cross-spec dependencies.
    - Verify that the entrypoint script is referenced by the Containerfile CMD.
    - Verify that the Caddyfile is referenced by the entrypoint script.
    - _Requirements: all_

  - [ ] 5.V Verify wiring group
    - [ ] All smoke tests pass
    - [ ] No unjustified stubs remain in touched files
    - [ ] All execution paths from design.md are live (traceable in code)
    - [ ] All cross-spec entry points are called from production code
    - [ ] All existing tests still pass: `make test-all`

## Traceability

| Requirement | Test Spec Entry | Implemented By Task | Verified By Test |
|-------------|-----------------|---------------------|------------------|
| 01-REQ-1.1 | TS-01-1, TS-01-3 | 2.1 | test/unit/test_caddyfile.sh |
| 01-REQ-1.2 | TS-01-P1 | 2.1, 2.2 | test/integration/test_container.sh |
| 01-REQ-1.3 | TS-01-1 | 2.1 | test/unit/test_caddyfile.sh |
| 01-REQ-1.E1 | TS-01-E1 | 2.1 | test/integration/test_container.sh |
| 01-REQ-1.E2 | TS-01-E2, TS-01-P6 | 3.2 | test/integration/test_container.sh |
| 01-REQ-2.1 | TS-01-SMOKE-1 | 4.1 | test/integration/test_container.sh |
| 01-REQ-2.2 | TS-01-SMOKE-1 | 4.1 | test/integration/test_container.sh |
| 01-REQ-2.3 | TS-01-8 | 4.1 | test/unit/test_caddyfile.sh |
| 01-REQ-2.E1 | TS-01-SMOKE-1 | 4.1 | test/integration/test_container.sh |
| 01-REQ-3.1 | TS-01-4, TS-01-P3 | 2.2 | test/unit/test_caddyfile.sh |
| 01-REQ-3.2 | TS-01-SMOKE-1 | 2.2 | test/integration/test_container.sh |
| 01-REQ-3.3 | TS-01-8 | 4.1 | test/unit/test_caddyfile.sh |
| 01-REQ-3.E1 | TS-01-E1 | 4.1 | test/integration/test_container.sh |
| 01-REQ-4.1 | TS-01-6, TS-01-P4 | 2.2 | test/unit/test_caddyfile.sh |
| 01-REQ-4.2 | TS-01-6, TS-01-P4 | 2.2 | test/unit/test_caddyfile.sh |
| 01-REQ-4.3 | TS-01-5 | 2.2 | test/unit/test_caddyfile.sh |
| 01-REQ-4.E1 | TS-01-E1 | 2.2 | test/integration/test_container.sh |
| 01-REQ-5.1 | TS-01-9, TS-01-P5 | 3.2 | test/unit/test_entrypoint.sh |
| 01-REQ-5.2 | TS-01-10, TS-01-SMOKE-2 | 3.2 | test/unit/test_entrypoint.sh |
| 01-REQ-5.3 | TS-01-9, TS-01-P5 | 3.1 | test/unit/test_entrypoint.sh |
| 01-REQ-5.4 | TS-01-SMOKE-2 | 3.3 | test/integration/test_container.sh |
| 01-REQ-5.E1 | TS-01-E2, TS-01-P6 | 3.2 | test/integration/test_container.sh |
| 01-REQ-5.E2 | TS-01-E3 | 3.1 | test/integration/test_container.sh |
| 01-REQ-6.1 | TS-01-2 | 2.1 | test/unit/test_caddyfile.sh |
| 01-REQ-6.2 | TS-01-7 | 4.1 | test/unit/test_caddyfile.sh |
| 01-REQ-6.E1 | TS-01-E2 | 3.2 | test/integration/test_container.sh |
| Property 1 | TS-01-P1 | 2.1, 2.2 | test/integration/test_container.sh |
| Property 3 | TS-01-P3 | 2.2 | test/integration/test_container.sh |
| Property 4 | TS-01-P4 | 2.2 | test/integration/test_container.sh |
| Property 5 | TS-01-P5 | 3.2 | test/integration/test_container.sh |
| Property 6 | TS-01-P6 | 3.2 | test/integration/test_container.sh |

## Notes

- No custom Go code is needed — all work is in config files and shell scripts.
- Integration tests require podman and a built container image.
- Property tests are implemented as parameterised shell loops within the
  integration test suite.
- The `example.com.caddy` snippet ships as a template/example; operators
  create their own snippets following the same pattern.
