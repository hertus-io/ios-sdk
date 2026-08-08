# Hertus for iOS

The native SDK. Every other Apple-backed SDK (Flutter, React Native, Unity,
Unreal, Godot) will bind to what this package produces, and none of them will
reference the identification vendor.

The contract it implements is `docs/SDK.md` in the platform repository, and the
public surface is generated from `sdk/contract/`. Read those first; this file is
about building and running.

A developer writing Swift is a first-class customer here, not somebody who
declined to use Flutter. Whatever a Flutter developer can express, this package
expresses, under the same type names and with the same validation.

## Targets

| Target | What it is |
| --- | --- |
| `HertusCore` | Platform independent. Foundation only. The event model, validation, state machine, retry schedule, wire format. No UIKit, nothing that needs a device. |
| `Hertus` | The product a host app depends on. The public facade plus the Apple platform layer: lifecycle, storage, networking, the Guard adapter. |

The split is not decoration. Everything with a decision in it lives in
`HertusCore`, so it can be tested on any machine with a Swift toolchain rather
than only on a Mac with a simulator. The layer above stays thin enough to read
in one sitting, because it is the part those tests cannot cover.

## Build and test

With a Swift toolchain on any host:

```bash
swift build
swift test
```

On Windows the toolchain needs its runtime DLLs on `PATH` before either works:

```powershell
$root = "$env:LOCALAPPDATA\Programs\Swift"
$env:Path = "$root\Toolchains\6.3.3+Asserts\usr\bin;$root\Runtimes\6.3.3\usr\bin;$env:Path"
swift test
```

That builds for the host, which is enough for `HertusCore` and is how its tests
run in development. Building **for iOS**, running on a simulator, and producing
an `.xcframework` all need a Mac with Xcode. Nothing in `HertusCore` may depend
on that being available.

## Parity with Android

The two native SDKs are generated from one contract and are meant to stay
recognisably the same library. Where Swift and Kotlin idioms genuinely differ,
the Swift one wins: `HertusValue` is an `enum` with associated values rather
than a class hierarchy, because that is what a Kotlin sealed class means in
Swift and it is what makes a `switch` exhaustive.

`HertusEvent` stays a class hierarchy in both, because inheritance is the point:
a typed subclass is a constructor, and every one of them serializes to the same
envelope.

## Naming discipline

No shipped artefact names the identification vendor. Not a type, not a field,
not an error code, not a message, not a log line above `verbose`. See
`docs/SDK.md`, "Naming discipline". The rule is enforced by a test rather than
by review.
