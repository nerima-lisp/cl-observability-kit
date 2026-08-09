# Development

## Repository checks

From the repository root, the standard development commands are:

```sh
nix develop
nix run .#test
sbcl --script run-tests.lisp
sbcl --script run-coverage.lisp
nix flake check
nix fmt
```

`nix flake show` exposes the test app as `.#test` (`nix run .#test`), the
repository checks, the formatter, and the package for the supported systems.
The direct SBCL scripts are useful when diagnosing ASDF or test-runner
behavior. The test system uses `cl-weave` and rejects an empty test selection.

The Nix shell provides the pinned `paredit-cli` executable as `paredit` for
read-only structural validation and analysis. Keep generated build output and
coverage artifacts out of the repository.

## Test and coverage boundary

`run-tests.lisp` bootstraps the local source registry, loads the test system,
and runs the complete cl-weave suite. `run-coverage.lisp` uses SBCL coverage
instrumentation and asks cl-weave for 100% expression and branch coverage.
The executable runtime files are included explicitly; these declaration and
macro-expansion files are excluded from runtime instrumentation:

```text
src/package.lisp
src/conditions.lisp
src/validation-data.lisp
src/metrics-declarations.lisp
src/metrics-macros.lisp
src/health-declarations.lisp
src/health-macros.lisp
src/context-declarations.lisp
src/context-macros.lisp
src/log-kit-macros.lisp
src/package-prometheus.lisp
src/package-otlp.lisp
src/package-log-kit.lisp
```

The excluded files are still exercised through compilation/loading and public
boundary tests. The coverage policy is therefore a runtime acceptance
boundary, not a claim that every source form receives SBCL instrumentation.

Coverage writes `coverage-report/` and the raw `coverage.sexp`. The filtered
report is the review artifact; the raw file may include dependency pathnames
and must not be treated as application telemetry. Set
`CL_WEAVE_PROPERTY_TESTS` and `CL_WEAVE_PROPERTY_SEED` to reproduce property
tests.

## Documentation checks

The site configuration is `docs/mkdocs.yml`, and its source is under
`docs/src/`. With MkDocs Material installed, build it strictly with:

```sh
mkdocs build --strict -f docs/mkdocs.yml
```

The current flake exposes test, formatting, package, and development-shell
outputs but does not expose a `packages.docs` output. Run the MkDocs command
directly when validating documentation; `nix flake check` does not currently
stand in for that site build.

## Source layout

The core source is split by responsibility: metric model, definition,
operation, and snapshot files; health model, registry, and execution files;
context and optional adapter files. Tests live in `t/` and are loaded through
the `cl-observability-kit/tests` system.

When public semantics change, update the API and architecture pages together
with the README entry point. Keep HTTP routes, exporter lifecycle, and
provider-specific policy in the application that integrates this package.
