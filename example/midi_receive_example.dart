import 'dart:io';

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

  print('connected to: ${device.toDictionary} \n' 'press q then enter to quit');
  stdin.listen((data) {
    if (data.first == 'q'.codeUnitAt(0)) {
      print('disconnecting');
      device.disconnect();
      exit(0);
    }
  });

  await device.receivedMessages.forEach((mesg) {
    print('MIDI MESG: ${mesg.toDictionary}');
  });
}
