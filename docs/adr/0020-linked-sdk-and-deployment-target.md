# 20. Record the active SDK independently of the deployment target

## Status

Accepted.

## Context

The app targets macOS 14 but builds with a current SDK. SwiftPM's Swift Build backend records
`sdk 14.0` alongside `minos 14.0` when given that deployment triple, even with the current `--sdk`.
macOS then gives the menu and Settings the legacy compatibility appearance. The native backend
records the actual SDK and keeps the deployment target. CI's macOS 26 image provides SDK 26+.

## Decision

Use SwiftPM's public `--build-system native` option for app builds, explicitly selecting the active
macOS SDK and macOS 14.0 deployment triple for both slices and local single-architecture builds.
Require SDK 26+. Verify each component's every slice with `vtool`: macOS platform, configured
`minos`, SDK major at least 26. Keep signing and size budgets unchanged (ADR 0014).

## Alternatives rejected

- Relying on SwiftPM's default backend: changes between toolchains and currently gives the wrong
  SDK stamp. Passing `--sdk` alone does not fix it.
- Swift Build settings such as `SDK_VERSION` or `MACOSX_DEPLOYMENT_TARGET`: SwiftPM exposes no
  documented CLI build-setting override for these; the deployment triple already expresses the
  minimum correctly.
- Adding linker `-platform_version` overrides: duplicates the driver's platform-version arguments
  and couples the script to their order. Let the driver derive the SDK instead.
- Patching load commands after linking: would conceal a build error instead of fixing the build.
- Raising the deployment target to 26: would drop supported Macs.

## Consequences

Current native controls get macOS 26+ appearance without new UI APIs. The native backend is
deprecated in Swift 6.4; replace this choice when Swift Build stamps both values correctly,
retaining the verification gate. CI's release dry run exercises the gate, with a separate CLI
launch on macOS 15 (the oldest hosted image); macOS 14 and light/dark Settings need live checks.
