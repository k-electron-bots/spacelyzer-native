# Linux Swift preflight for scripts/docs-capture.swift

Goal: catch Swift compile errors in the macOS helper scripts on a free Linux toolchain before a Mac build, including the CoreFoundation downcast error class (`conditional downcast to CoreFoundation type ... will always succeed`). Run `scripts/linux-preflight/run-preflight.sh` from the repo root; it needs Swift 6.x (`swiftc`) and fails if it is missing. Three layers; all three are required (limits below).

## 0. Toolchain (free, no account)
Official Swift tarball:
- 5.10.1: https://download.swift.org/swift-5.10.1-release/ubuntu2204/swift-5.10.1-RELEASE/swift-5.10.1-RELEASE-ubuntu22.04.tar.gz (605 MB)
- 6.1.2:  https://download.swift.org/swift-6.1.2-release/ubuntu2204/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-ubuntu22.04.tar.gz (878 MB)
Index: https://www.swift.org/install/linux/ . Trap: apt's `swift` package is OpenStack object storage, NOT the language.
    tar xzf swift-*.tar.gz -C /tmp && SW=/tmp/swift-*-RELEASE-ubuntu22.04/usr/bin/swiftc && $SW --version

## Layer 1 - idiom lint (no toolchain needed, seconds)
    bash cf-idiom-lint.sh scripts/docs-capture.swift
Flags (a) any single-value `as? AX/CF/CG...` downcast (the hard-error class; proven-safe idioms
are `as? [T]` arrays, nil-guard + `as! T`, kCFBooleanTrue) and (b) `true/false as CFTypeRef`.
It flags the old patterns (`as? AXUIElement`, `true as CFTypeRef`) and is clean on the fixed helper.

## Layer 2 - real-CoreFoundation old-fail/new-pass reproduction
proves the error class itself fires on Linux (it is NOT macOS-only; only the AX SDK is):
    $SW -typecheck repro-old.swift    # MUST fail: "conditional downcast to CoreFoundation type 'CFString' will always succeed" (rc 1)
    $SW -typecheck repro-fixed.swift  # MUST pass (rc 0): nil-guard on CFTypeRef? then `as! CFString`

## Layer 3 - full-helper stub typecheck (catches syntax/symbol/type errors across the whole file)
The helper uses macOS-only modules (AppKit, ApplicationServices, CoreGraphics, Darwin).
Shim recipe (sed, run from repo root):
    sed -e 's/^import AppKit$/import Glibc/' \
        -e '/^import ApplicationServices$/d' \
        -e '/^import CoreGraphics$/d' \
        -e '/^import Darwin$/d' \
        scripts/docs-capture.swift > /tmp/swiftcheck/main.swift
Then typecheck against the stub SDK:
    $SW -typecheck /tmp/swiftcheck/main.swift stubs.swift   # MUST be rc 0, zero diagnostics
stubs.swift declares the ~40 symbols the helper needs, aliased to real Foundation types
(CFString=NSString, CFTypeRef=AnyObject, AXUIElement=NSString, AXValue=NSNumber,
CFArray=NSArray, CFBoolean=NSNumber, plus AX functions, CFHash/CFEqual, NSRunningApplication,
CGEvent/CGWindowList*, CGPoint/CGSize, kCG*/kCFBooleanTrue constants).
A dropped call argument and a tuple misuse are both caught.

## Limits (do not skip Layer 1/2 because Layer 3 is green)
- Layer 3 alone CANNOT catch the 185:54 class: with AXUIElement aliased to NSString the
  CF downcast rule does not fire (the old failing helper passes Layer 3 clean).
  That class is covered ONLY by Layer 1 (lint) and Layer 2 (real-CF reproduction).
- Stub declarations are hand-written: errors depending on Apple's exact declarations
  (deprecation-as-error, availability annotations, AX semantics, exact macOS signatures)
  cannot fire. Native SDK behavior is NOT proved by this preflight.
- String literal -> CFString via `as` fails on Linux (no corelibs bridging) - that is why
  stubs use NS aliases; a naive compile drowns in false positives.
- Compiler version: the Mac workflow runs swiftc without `-swift-version`, i.e. Swift 5 language mode; the preflight needs Swift 6.x.
