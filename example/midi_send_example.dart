import 'dart:typed_data';

import 'package:midi/midi.dart';

void main() async {
  final devices = AlsaMidiDevice.getDevices();

  for (final d in devices) {
    print('found device: ${d.toDictionary}');
  }
  if (devices.isEmpty) {
    print('no midi devices found');
    return;
  }
  // use first device found
  final device = devices.first;

  await device.connect();

  print('connected to: ${device.toDictionary} \n' 'ctrl-C to quit');

  print('sending command to turn all LEDs OFF on a Akai Fire');
  final data = Uint8List.fromList([0xB0, 0x7F, 0]);
  device.send(data);
  print('disconnecting');
  device.disconnect();
}
