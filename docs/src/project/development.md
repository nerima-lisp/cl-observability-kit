# Development

## Repository checks

From the repository root, the standard development commands are:

~~~sh
nix develop
nix run .#test
sbcl --script run-tests.lisp
sbcl --script run-coverage.lisp
nix flake check
nix build .#docs
nix fmt
~~~

nix flake show exposes the test app as .#test, the repository checks, the
formatter, the documentation site as .#docs, and the package for the
supported systems. The direct SBCL scripts are useful when diagnosing ASDF
or test-runner behavior. The test system uses cl-weave and rejects an empty
or partially non-runnable test selection.

The Nix shell provides the pinned `paredit-cli` package; its executable is
`paredit`. Use it for read-only structural validation and analysis. Keep
generated build output and coverage artifacts out of the repository.

## Continuous integration

Four GitHub Actions workflows share one `nix-setup` composite action, which is
the single place the Nix installer and Cachix action revisions are pinned:

| Workflow | Trigger | What it enforces |
| --- | --- | --- |
| ci.yml | push to main, pull request | `nix flake check` and `git diff --check` |
| docs.yml | push to main touching docs or the flake | Builds `.#docs` and publishes it to GitHub Pages |
| release.yml | push of a `v*.*.*` tag | The tag matches every `:version` in the .asd, `nix flake check` passes on the tagged tree, then a draft release is opened |
| flake-update.yml | weekly, or manual dispatch | Proposes a `flake.lock` update as a pull request |

CI runs on Linux only. The flake declares `aarch64-darwin` as well, and that
attribute set is covered by developers running the commands above locally.

## Test and coverage boundary

run-tests.lisp bootstraps the local source registry, loads the test system,
and runs the complete cl-weave suite. run-coverage.lisp uses SBCL coverage
instrumentation and asks cl-weave for 100% expression and branch coverage.
The executable runtime files are included explicitly; these declaration and
macro-expansion files are excluded from runtime instrumentation:

~~~text
src/package.lisp
src/conditions.lisp
src/validation-data.lisp
src/metrics-declarations.lisp
src/metrics-macros.lisp
src/health-declarations.lisp
src/health-macros.lisp
src/context-declarations.lisp
src/context-macros.lisp
src/resource-declarations.lisp
src/trace-declarations.lisp
src/trace-macros.lisp
src/log-declarations.lisp
src/log-kit-macros.lisp
src/package-prometheus.lisp
src/package-otlp.lisp
src/package-log-kit.lisp
~~~

The excluded files are still exercised through compilation/loading and public
boundary tests. The coverage policy is therefore a runtime acceptance
boundary, not a claim that every source form receives SBCL instrumentation.

Coverage writes coverage-report/ and the raw coverage.sexp. The filtered
report is the review artifact; the raw file may include dependency pathnames
and must not be treated as application telemetry. Set CL_WEAVE_PROPERTY_TESTS
and CL_WEAVE_PROPERTY_SEED to reproduce property tests.

## Performance checks

Run the repeatable SBCL workload benchmark and allocation profile from the
repository root:

~~~sh
nix develop --command sbcl --script scripts/performance-benchmark.lisp
nix develop --command sbcl --script scripts/performance-profile.lisp
~~~

The benchmark reports elapsed time and allocated bytes for metric updates,
snapshots, Prometheus exposition, OTLP conversion, and context capture. It
also checks that exporter workloads produce non-empty Prometheus and OTLP
outputs. Compare runs on the same implementation and machine; the profile is
an allocation hotspot signal, not a substitute for functional tests.

## Documentation checks

The site configuration is docs/mkdocs.yml, and its source is under docs/src/.
With MkDocs Material installed, build it strictly with:

~~~sh
mkdocs build --strict -f docs/mkdocs.yml
~~~

The flake exposes the rendered site as .#docs; its build uses MkDocs Material
with --strict and asserts that index.html was produced. Verify the flake
artifact itself when reviewing a docs change:

~~~sh
nix build .#docs
test -L result
find -L result -type f -size +0c -print | rg -m 1 .
~~~

## Source and test layout

The core source is split by responsibility: metric model, definition,
operation, snapshot, SDK provider/reader, and periodic reader files; health
model, registry, thread, and execution files; context, resource, trace,
trace processors, sampler, propagation, structured-log, log SDK,
configuration, and HTTP semantic-convention files. Prometheus source
selection, formatting, and sample emission are separate files, as are OTLP
common helpers, signal-specific conversion, and the optional cl-log-kit bridge.

Tests live in t/ and are loaded through the cl-observability-kit/test system.
Metric SDK and periodic lifecycle contracts live beside trace SDK, trace
processor, log SDK, propagation, and configuration contracts. When adding a
public lifecycle callback, include tests for success, callback failure
isolation, repeated flush, shutdown, and detached data. For built-in span
processors, also cover synchronous export, delayed partial batches, bounded
queue overflow, exporter errors, and worker shutdown.

When public semantics change, update the API and architecture pages together
with the README entry point. Keep HTTP clients and servers, wire encoding,
network exporter lifecycle, logger sinks, network batch/retry policy, and
provider-specific deployment policy in the application or integration that
owns them.
