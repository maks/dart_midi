## 0.1.1
- fix(linux): prevent ALSA shutdown hang and CPU spin
- fix(linux): prevent CPU spin in non-blocking MIDI read loop
- fix(linux): graceful isolate shutdown to prevent ALSA assertion crash
- fix: close ALSA input port before killing isolate to allow clean shutdown

## 0.1.0
  - update to support Dart 3, update dependencies to match

## 0.0.5
  - handling for device removal (thanks to Morten Boye Mortensen)
  - update to latest FFI package version (thanks to Morten Boye Mortensen)

## 0.0.4
  - Add support for **receiving** sysex messages

## 0.0.3
  - Add hardwareId static method

## 0.0.2
  - Mark package as only supporting Linux

## 0.0.1

- Initial version.
