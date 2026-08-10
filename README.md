# cl-observability-kit

cl-observability-kit is a deterministic, transport-neutral observability
foundation for Common Lisp. It covers the three telemetry signals—metrics,
traces, and structured logs—plus health checks, resource metadata,
instrumentation context, propagation, and HTTP semantic conventions.

The SDK layer includes synchronous and observable metric instruments, detached
snapshots, readers, periodic collection, tracer and meter providers, span and
log processors, samplers, lifecycle callbacks, and a validated environment
configuration parser. Propagation adapters cover W3C Trace Context and
Baggage, B3, B3 multi-header, Jaeger, and AWS X-Ray carriers.

The transport boundary is deliberate. Applications and integration packages
own HTTP clients and servers, logger sinks, wire encoding, batching policy,
retries, and network exporter I/O. The core never opens a connection or starts
a network thread.

## Quick start

~~~lisp
(defparameter *registry* (observability-kit:make-metric-registry))
(defparameter *requests*
  (observability-kit:define-counter
   *registry* requests-total
   :help "Completed requests."
   :label-names '("method" "status")))
(observability-kit:metric-inc
 *requests* 1
 :labels '(("method" . "GET") ("status" . "200")))
(observability-kit/prometheus:render-prometheus *registry*)
~~~

Metric definitions require symbol names, and labelled updates require the
complete declared label set. See [Getting started](docs/src/getting-started.md)
for provider lifecycle, health checks, tracing, logs, propagation, and
transport adapters.

The optional observability-kit/otlp package converts metric snapshots, span
records, and log records into detached OTLP-shaped Common Lisp data. It does
not serialize or send a wire payload.

## Install

Make the checkout containing cl-observability-kit.asd visible to ASDF, then
load the system:

~~~lisp
(asdf:load-system "cl-observability-kit")
~~~

nix develop provides the pinned development dependencies. This repository
does not currently publish a release tag, so source-checkout installation is
the reproducible option documented here.

## Documentation

- [Getting started](docs/src/getting-started.md)
- [API reference](docs/src/reference/api.md)
- [Architecture](docs/src/reference/architecture.md)
- [Development](docs/src/project/development.md)

## Development

~~~sh
nix develop
nix run .#test
sbcl --script run-tests.lisp
sbcl --script run-coverage.lisp
nix flake check
nix build .#docs
nix fmt
~~~

Tests live in t/ and use cl-weave. The coverage runner requires 100%
expression and branch coverage for its explicit runtime boundary; see the
[development guide](docs/src/project/development.md) for the exclusions and
artifact policy.

## Contributing

Keep the core transport-neutral and update the documentation when public
semantics change. Run the checks above before opening an issue or pull request.

## Support

Please use the [GitHub issue tracker](https://github.com/nerima-lisp/cl-observability-kit/issues)
for reproducible bugs and feature discussions.

## License

MIT, as declared by cl-observability-kit.asd.
