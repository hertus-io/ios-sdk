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
| `HertusCore` | Platform independent. Foundation only. The event model, validation, state machine, retry schedule, wire format, and all of Guard except the engine itself. No UIKit, nothing that needs a device. |
| `Hertus` | The product a host app depends on. The public facade plus, later, the Apple platform layer: lifecycle, storage, networking. |
| `HertusGuardS1` | The adapter onto the identification engine. The only target in the package that imports it, and the only one that names it. Opted into separately. |

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

## The sample

```bash
swift run hertus-sample
```

A console program rather than a screen, so it runs on a machine with no
simulator. It builds one of every event, prints the envelope each produces,
and shows what validation does to a lowercase currency code, a negative
amount, a non-finite number and an unusable event name.

It makes no network call and starts no engine, and says so on the way out. A
SwiftUI sample arrives when `Hertus.initialize` and `Hertus.track` do, because
a screen whose buttons do nothing is worse than no screen.

## Guard

The fraud module. It answers one question, whether this device is what it claims
to be, and it does so by wrapping a third party engine rather than by
fingerprinting devices itself.

```swift
HertusGuardS1.enable()
Hertus.initialize(config)
```

One line, and it has to be written. Swift has no portable equivalent of the
reflection the Android SDK uses to find its adapter, so registration through
`SignalEngineFactory` is explicit here. That is a trade rather than a loss: on
Android the reflective lookup is invisible to R8, which strips the adapter from
minified builds and turns Guard into a no-op indistinguishable from a correctly
disabled Guard, and a keep rule has to ship inside the AAR to prevent it.
Nothing can strip a registration that was executed.

Not calling it is a supported configuration. `enable()` returns whether there
was an engine to register, and a build without one runs with Guard off rather
than failing.

**The state of this.** Everything except the engine binding is written and
tested: the seam, the orchestration, the registry, the settings validation, the
degradation rules and the logging discipline. The adapter in `HertusGuardS1` is
compiled only when the engine is present, and the engine dependency is not
declared yet, so that file has not been compiled anywhere. Adding the dependency
and verifying the mapping is a Mac-side change, because the engine ships as an
Apple binary.

Guard also does nothing end to end until bootstrap exists, on either platform:
the server currently answers `guard.enabled: false` and has never composed the
block that turns it on. See `docs/SDK.md`, "What must exist first".

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
