# 1. A transport protocol over IOKit, with a stateful fake HID++ device for tests

## Status

Accepted, not built

## Context

No code above `Report` parsing has tests. The daemon's open bugs are behaviours of `HIDPPDevice`
and `Session` against a device, and a live check cannot reproduce a stale diversion after a crash,
a HID++ 1.0 slot, or a mouse nobody on the project owns.

## Decision

Add a main-actor `HIDPPTransport` protocol (send, subscribe, unsubscribe, identity) that
`Sources/HIDPP/HIDInterface.swift#HIDInterface` conforms to. A test-only target provides a fake
transport and a stateful fake device built from saved `puremouse probe` output. Tests check the
device's end state, and check the order of requests only where order is the invariant (wheels
before controls when restoring). A session environment seam and a task-local log capture let
`Session` run under test.

## Alternatives rejected

- Scripted request and reply transcripts: they break on any harmless reordering.
- Mocking at the session level with a fake `HIDPPDevice`: it skips the request state machine
  (software ID rotation, timeouts, cancellation), where several invariants live.
- Moving IOKit into its own target now, for other platforms: not promised; the protocol leaves
  that possible later.

## Consequences

- About 400-600 lines of test support, never linked into the apps.
- The probe output format becomes a fixture contract: changing it means updating fixtures.
- A request for a new mouse becomes a fixture and a test, and daemon fixes are written test first.
