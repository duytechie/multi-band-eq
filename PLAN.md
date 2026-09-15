# Native macOS 31-band equalizer

## Goal and assumptions

Build a small native Swift app that applies a graphic equalizer to audio from other apps on the Mac. Match the functional simplicity of the supplied Windows reference, with an always-visible decimal dB value for every band.

The repository currently contains only a README. This document is an implementation plan; no application has been built yet.

Working assumptions:

- System-wide playback processing, targeting the current default stereo output device.
- macOS 14.2 minimum, subject to verification in the audio prototype; test the oldest supported release and current macOS.
- SwiftUI interface with AppKit where native slider and window behavior benefit from it.
- Direct distribution as a signed, notarized app for the first release.
- The screenshot is a visual reference. The exact semantics of its Mode, secondary selector, and Auto controls cannot be established from the image alone. Proposed behavior appears below.

## Interface and behavior

One resizable window, approximately 1,200 × 560 points initially. Use native macOS controls, system fonts, light/dark appearance, and a clear zero-dB guide. Keep all 31 bands visible at the preferred width; allow horizontal scrolling at smaller widths instead of making controls unreadable.

| Control | Planned behavior |
| --- | --- |
| 31 vertical faders | Fixed center frequencies; gain from −12.0 to +12.0 dB. |
| Per-band numeric value | Always visible beneath every fader, e.g. `−3.2`, with a shared dB label. Click to edit precisely. Store gain as `Float`; use 0.1 dB UI steps and normalize negative zero. |
| Frequency label | Below each value; use readable labels such as `1k`, `1.25k`, and `20k`. |
| Fine adjustment | Arrow keys change 0.1 dB; Shift-arrow changes 1.0 dB. Double-click a fader to reset that band. Expose frequency and gain to VoiceOver. |
| Selected band | Frequency selector and editable signed dB field, synchronized with the fader and its inline value. |
| Reset | Set all band gains and master gain to 0.0 dB. |
| Mode | Default: Stereo linked, applying the same curve to L/R while preserving stereo. Optional reference-parity mode: independent L/R curves with a channel selector. Do not equate linked EQ with summing audio to mono. |
| Volume | DSP master gain, proposed range −24.0 to +12.0 dB, with an editable decimal value. This is separate from the Mac's hardware volume. |
| Auto / Live preview | Proposed interpretation: checked means edits are heard immediately; unchecked means edits remain pending until Apply. Label it Live preview to make the behavior explicit. |
| Apply / Cancel | Apply commits pending changes; Cancel restores the values saved when the editing session opened, including any live preview changes. Closing the editor follows Cancel semantics. |
| Import / Export | Native file dialogs for a small, versioned JSON preset containing frequencies, gains, master gain, and channel mode. Validate the whole file before applying it. Windows format compatibility requires a sample exported file. |
| Enable EQ | A single bypass toggle for comparing the processed sound with the original. |

Band centers in Hz:

```text
20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000,
12500, 16000, 20000
```

Persist committed settings across launches. Closing the editor leaves committed EQ running; Quit stops processing and restores ordinary playback. A minimal menu-bar item provides Open, Enable EQ, and Quit so the app remains accessible.

## Audio design

### Prove routing first

Apple documents process taps and their use with an aggregate audio device on macOS 14.2 and later. Capturing requires an `NSAudioCaptureUsageDescription` entry and system audio recording permission. This supplies the starting point for an implementation without a separately installed third-party driver. [Apple's capture sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

Proposed signal path:

```text
Other apps → Core Audio process tap → private aggregate input
          → bounded audio buffer → master gain → 31-band EQ
          → current default output device
```

Exclude this app's playback from capture to prevent feedback. Use the tap's `mutedWhenTapped` behavior to suppress the original audio while reading the tap; verify startup, teardown, and crash behavior on real hardware. Apple documents that this mode mutes the source during tap read activity. [Tap mute behavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)

Prototype the Core Audio input/output bridge before committing to its final shape. Start with a private aggregate device and a pull-driven render path; prove format negotiation, buffering, clock synchronization, and drift handling. If separate capture/playback clocks are needed, implement bounded buffering and rate matching rather than relying on a queue that can grow indefinitely.

Do not describe this as universal interception until the prototype establishes which applications and routes are supported. Validate ordinary music/video playback, browser audio, system sounds, and capture-restricted sources; report unsupported paths clearly.

### Equalizer processing

Start with `AVAudioUnitEQ(numberOfBands: 31)`, using fixed-frequency parametric filters and an initial bandwidth of one-third octave. Apple exposes frequency, bandwidth, gain, and global gain through this unit. Measure the resulting combined frequency response before treating the design as final. [AVAudioUnitEQ](https://developer.apple.com/documentation/avfaudio/avaudiouniteq), [filter type](https://developer.apple.com/documentation/avfaudio/avaudiouniteqfiltertype/parametric), [bandwidth](https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/bandwidth)

- Treat it as a new graphic EQ with similar controls; matching the Windows application's exact sound requires knowing its filter design.
- Ramp gain changes to prevent clicks. Verify that the selected Audio Unit supports the needed parameter scheduling; otherwise perform smoothing in a dedicated render component.
- Keep allocations, locks, file access, logging, and Swift concurrency work outside real-time audio callbacks. Pass parameter updates through a bounded mechanism suitable for the callback.
- Keep processing in floating point. Positive EQ gains can clip at the output: retain manual master attenuation and show a small clipping indicator. Do not silently change user gains or add an unrequested compressor.
- Test combined boosts; overlapping filters can produce more gain than any single fader value suggests.
- Respect each device's sample rate. Disable bands at or above Nyquist (half the sample rate), preserving their preset values for later restoration. Apple bounds EQ frequency by the sample rate. [Frequency limits](https://developer.apple.com/documentation/avfaudio/avaudiouniteqfilterparameters/frequency)
- For independent L/R mode, use separate channel processing paths. The first audio milestone only needs the shared stereo curve.

## Suggested code structure

```text
MultiBandEQ/
  App/                 app lifecycle, menu bar, window
  Models/              EQ state, band definitions, preset schema
  Views/               equalizer window, band fader, gain editor
  Audio/               tap lifecycle, device routing, render bridge, EQ
  Persistence/         settings and preset import/export
MultiBandEQTests/       model, preset, and offline DSP checks
```

Keep editable state, committed state, and currently rendered parameters distinct so Apply, Cancel, and live preview remain predictable. Keep audio-device lifecycle management separate from UI state.

## Build milestones and acceptance gates

### 1. Audio feasibility prototype

- Build a signed app bundle with capture permission handling.
- Capture other apps, exclude self, and play through the default output with flat EQ.
- Add one working EQ band to prove processing is audible.
- Verify no doubled audio or feedback; normal playback returns after disable, Quit, and forced termination.
- Exercise permission denial/revocation, default output changes, unplugging devices, and sleep/wake.
- Measure added latency, CPU use, and dropouts. Initial target: under 20 ms added latency on wired/built-in output, subject to measurement; report Bluetooth latency separately.

Exit gate: reliable processed playback and recovery on the chosen minimum macOS version. If taps fail this gate, document the specific failure and reconsider routing before expanding the UI. An external loopback device is a fallback architecture decision, not a silent dependency.

### 2. Full equalizer editor

- Implement all 31 sliders, inline decimal editing, selected-band field, master gain, reset, and bypass.
- Connect the full stereo-linked EQ and parameter smoothing.
- Verify keyboard access, decimal parsing, invalid input handling, resizing, and both appearances.

### 3. Reference workflow and persistence

- Implement live preview, Apply/Cancel, preset import/export, and saved committed settings.
- Add independent L/R mode and channel selection if retaining the proposed reference-parity scope.
- Verify preset round trips, malformed-file rejection, channel isolation, and restoration on relaunch.

### 4. Audio validation and packaging

- Offline impulse/sweep checks: flat response, representative cuts/boosts, frequency centers, combined boosts, finite output, and low-sample-rate handling.
- Hardware checks: built-in output, a USB interface, Bluetooth, 44.1/48/96 kHz where supported, device switching, and an extended playback session.
- Confirm crash recovery, no persistent unwanted aggregate devices, and clear permission/device error states.
- Produce a signed and notarized build with a short setup guide and documented supported configurations.

## Scope boundary

The first release is the equalizer editor and the audio plumbing necessary to make it useful. Spectrum analysis, AI presets, per-app mixing, cloud sync, and a preset marketplace are outside this plan. Decimal dB values on every band are part of the core interface.
