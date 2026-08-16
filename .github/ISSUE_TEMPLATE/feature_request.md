---
name: Feature request
about: Propose a scoped improvement for cl-observability-kit
title: "[feature] "
labels: ["enhancement"]
---

## Problem

Describe the workflow limitation or missing capability.

## Proposed Change

Describe the smallest change that would solve the problem.

## Validation Plan

Describe how the change should be tested or demonstrated.

## Scope Check

Explain why this belongs in the core rather than at the application boundary.
The core owns validated telemetry data, aggregation semantics, and lifecycle;
it does not own HTTP clients or servers, route handlers, wire encoding, logger
sinks, transport retry policy, or network exporter I/O.

## Public Surface Notes

Call out any impact on exported symbols, conditions, validation rules, or
adapter output.
