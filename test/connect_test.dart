import 'dart:io';

import 'package:midi/alsa_midi_device.dart';
import 'package:test/test.dart';

extension on AlsaMidiDevice {
  String get hwrId => AlsaMidiDevice.hardwareId(cardId, deviceId);
}

void main() {
  /// This tried to connect to a device, make sure the device is
  /// mark as connected and then disconnect it
  test('connect/connected', () async {
    if (!Platform.isLinux) {
      // Skip this test on Windows and macOS
      return;
    }
    var devices = AlsaMidiDevice.getDevices();
    AlsaMidiDevice? connectedDevice;
    for (var device in devices) {
      // Try a device until it succeeds
      try {
        var connected = (await device.connect().timeout(Duration(seconds: 5)));
        if (connected) {
          connectedDevice = device;
          break;
        }
      } catch (_) {}
    }

    if (connectedDevice != null) {
      try {
        var device = connectedDevice;

        /// List the devices again to make sure it is marked as connected
        var devices = AlsaMidiDevice.getDevices();
        var sameDevice = devices.firstWhere(
          (d) => d.deviceId == device.deviceId,
        );
        expect(sameDevice.connected, isTrue);

        /// Make sure we get the deconnected event
        var disconnectedFuture = AlsaMidiDevice.onDeviceDisconnected.firstWhere(
            (disconnectedDevice) => device.hwrId == disconnectedDevice.hwrId);
        device.disconnect();
        await disconnectedFuture;
        connectedDevice = null;
        expect(sameDevice.connected, isFalse);
      } finally {
        connectedDevice?.disconnect();
      }
    }
  }); // Skip this test if no device is connected
}
