## Summary

Describe the change in terms of user-visible behavior or contract impact.

## Validation

List the narrowest commands that demonstrate the change, and their results.

## Transport Boundary Impact

Confirm the change keeps HTTP clients and servers, wire encoding, logger
sinks, network retry policy, and exporter I/O outside the core, or explain why
the boundary moved.

## Public Surface Impact

Describe any change to exported symbols, conditions, validation rules,
lifecycle callbacks, or the Prometheus/OTLP/log-kit adapter output.

## Follow-up Risk

Call out any remaining risk, unsupported edge case, or intentional follow-up.
