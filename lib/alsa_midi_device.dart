// ignore_for_file: non_constant_identifier_names, constant_identifier_names

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:midi/midi.dart';

import 'alsa_generated_bindings.dart' as a;

final alsa = a.ALSA(DynamicLibrary.open('libasound.so.2'));

const SND_RAWMIDI_STREAM_INPUT = 1;
const SND_RAWMIDI_STREAM_OUTPUT = 0;

/// Happens in non-blocking mode when the read buffer is empty
const SND_RAWMIDI_ERROR_EAGAIN = -11; // Resource temporarily unavailable

/// Error when device is disconnected/closed
const SND_RAWMIDI_ERROR_ENODEV = -19; // No such device
const SND_RAWMIDI_ERROR_EBADFD = -77; // File descriptor in bad state

String stringFromNative(Pointer<Char> pointer) {
  return pointer.cast<Utf8>().toDartString();
}

int lengthOfMessageType(int type) {
  int midiType = type & 0xF0;

  switch (type) {
    case 0xF6:
    case 0xF8:
    case 0xFA:
    case 0xFB:
    case 0xFC:
    case 0xFF:
    case 0xFE:
      return 1;
    case 0xF1:
    case 0xF3:
      return 2;
    default:
      break;
  }

  switch (midiType) {
    case 0xC0:
    case 0xD0:
      return 2;
    case 0xF2:
    case 0x80:
    case 0x90:
    case 0xA0:
    case 0xB0:
    case 0xE0:
      return 3;
    case 0xF0:
      return -1;
    default:
      break;
  }
  return 0;
}

/// Arguments passed to the receive isolate
class _RxIsolateArgs {
  final SendPort sendPort;
  final int inPortAddress;
  final SendPort readyPort;

  _RxIsolateArgs(this.sendPort, this.inPortAddress, this.readyPort);
}

Future<void> _rxIsolate(_RxIsolateArgs args) async {
  final sendPort = args.sendPort;
  final Pointer<a.snd_rawmidi_> inPort = Pointer<a.snd_rawmidi_>.fromAddress(
    args.inPortAddress,
  );

  // Create a receive port for stop signals
  final stopPort = ReceivePort();
  bool shouldStop = false;

  // Send back the stop port so the main isolate can signal us
  args.readyPort.send(stopPort.sendPort);

  // Listen for stop signal (non-blocking)
  stopPort.listen((_) {
    shouldStop = true;
    stopPort.close();
  });

  int status = 0;
  int msgLength = 0;
  Pointer<Uint8> buffer = calloc<Uint8>();
  List<int> rxBuffer = [];
  bool isSysex = false;

  while (!shouldStop) {
    if ((status = alsa.snd_rawmidi_read(inPort, buffer.cast(), 1)) < 0) {
      if (status == SND_RAWMIDI_ERROR_EAGAIN) {
        // No data available in non-blocking mode
        // Yield to the event loop to allow stop signal to be processed
        await Future.delayed(Duration.zero);
        continue;
      } else if (status == SND_RAWMIDI_ERROR_ENODEV ||
          status == SND_RAWMIDI_ERROR_EBADFD) {
        // Device was disconnected or port was closed - exit gracefully
        break;
      } else {
        // Other error - exit the loop
        print(
          'Problem reading MIDI input status: $status => ${stringFromNative(alsa.snd_strerror(status))}',
        );
        break;
      }
    } else {
      if (rxBuffer.isEmpty) {
        msgLength = lengthOfMessageType(buffer.value);
        if (msgLength == -1) {
          isSysex = true;
        }
      }

      rxBuffer.add(buffer.value);

      if (rxBuffer.length == msgLength) {
        sendPort.send(Uint8List.fromList(rxBuffer));
        rxBuffer.clear();
      } else if (isSysex && buffer.value == 0xF7) {
        sendPort.send(Uint8List.fromList(rxBuffer));
        rxBuffer.clear();
        isSysex = false;
      }
    }
  }

  // Clean up
  calloc.free(buffer);
  // Signal that we've stopped
  sendPort.send(null);
}

class AlsaMidiDevice {
  static final Map<String, AlsaMidiDevice> _connectedDevices =
      <String, AlsaMidiDevice>{};
  static final StreamController<AlsaMidiDevice> _disconnectStreamCtrl =
      StreamController.broadcast();
  static Stream<AlsaMidiDevice> get onDeviceDisconnected =>
      _disconnectStreamCtrl.stream.asBroadcastStream();

  Pointer<Pointer<a.snd_rawmidi_>>? outPort;
  Pointer<Pointer<a.snd_rawmidi_>>? inPort;
  final StreamController<MidiMessage> _rxStreamCtrl;
  Isolate? _isolate;

  ReceivePort? errorPort;
  ReceivePort? receivePort;
  SendPort? _stopPort; // Port to signal the isolate to stop
  Completer<void>? _isolateStoppedCompleter; // Completes when isolate confirms stop

  Pointer<a.snd_ctl_> ctl;

  String type;
  int cardId;
  int deviceId;

  bool connected = false;

  String name;

  Stream<MidiMessage> get receivedMessages => _rxStreamCtrl.stream;

  final List<String> _inputPorts = [];
  final List<String> _outputPorts = [];

  List<String> get inputPorts => _inputPorts;
  List<String> get outputPorts => _outputPorts;

  AlsaMidiDevice(
    this.ctl,
    this.cardId,
    this.deviceId,
    this.name,
    this.type,
    this._rxStreamCtrl,
  ) {
    // Fetch device info
    var info = calloc<Pointer<a.snd_rawmidi_info_>>();
    alsa.snd_rawmidi_info_malloc(info);
    alsa.snd_rawmidi_info_set_device(info.value, deviceId);

    var status = alsa.snd_ctl_rawmidi_info(ctl, info.value);
    if (status < 0) {
      print(
        'error: cannot get device info.value ${alsa.snd_strerror(status).cast<Utf8>().toDartString()}',
      );
      return;
    }

    // Get input ports
    alsa.snd_rawmidi_info_set_stream(info.value, SND_RAWMIDI_STREAM_INPUT);
    status = alsa.snd_ctl_rawmidi_info(ctl, info.value);
    final inCount = alsa.snd_rawmidi_info_get_subdevices_count(info.value);
    for (var i = 0; i < inCount; i++) {
      if (alsa.snd_rawmidi_info_get_subdevice(info.value) < 0) {
        print(
          'error: snd_rawmidi_info_get_subdevice in [$i] $status ${alsa.snd_rawmidi_info_get_subdevice_name(info.value).cast<Utf8>().toDartString()}',
        );
      } else {
        _inputPorts.add('$i');
      }
    }

    // Get output ports
    alsa.snd_rawmidi_info_set_stream(info.value, SND_RAWMIDI_STREAM_OUTPUT);
    status = alsa.snd_ctl_rawmidi_info(ctl, info.value);
    final outCount = alsa.snd_rawmidi_info_get_subdevices_count(info.value);
    for (var i = 0; i < outCount; i++) {
      if (alsa.snd_rawmidi_info_get_subdevice(info.value) < 0) {
        print(
          'error: snd_rawmidi_info_get_subdevice out [$i] $status ${alsa.snd_rawmidi_info_get_subdevice_name(info.value).cast<Utf8>().toDartString()}',
        );
      } else {
        _outputPorts.add('$i');
      }
    }
    calloc.free(info);
  }

  Future<bool> connect() async {
    outPort = calloc<Pointer<a.snd_rawmidi_>>();
    inPort = calloc<Pointer<a.snd_rawmidi_>>();

    Pointer<Char> name = '${hardwareId(cardId, deviceId)},0'
        .toNativeUtf8()
        .cast<Char>();
    var status = 0;
    if ((status = alsa.snd_rawmidi_open(
          inPort!,
          outPort!,
          name,
          a.SND_RAWMIDI_NONBLOCK,
        )) <
        0) {
      print(
        'error: cannot open card number $cardId ${stringFromNative(alsa.snd_strerror(status))}',
      );
      return false;
    }

    connected = true;

    /// Register this device as connected globally
    _connectedDevices[hardwareId(cardId, deviceId)] = this;

    errorPort = ReceivePort();
    receivePort = ReceivePort();

    // Create a port to receive the stop port from the isolate
    final readyPort = ReceivePort();
    final readyCompleter = Completer<SendPort>();
    readyPort.listen((message) {
      if (message is SendPort) {
        readyCompleter.complete(message);
        readyPort.close();
      }
    });

    _isolate = await Isolate.spawn(
      _rxIsolate,
      _RxIsolateArgs(receivePort!.sendPort, inPort!.value.address, readyPort.sendPort),
      onError: errorPort!.sendPort,
    );

    // Wait for the isolate to send us its stop port
    _stopPort = await readyCompleter.future;

    errorPort?.listen((message) {
      print('isolate error message $message');
      disconnect();
    });

    receivePort?.listen((data) {
      if (data == null) {
        // Isolate signaled it has stopped
        _isolateStoppedCompleter?.complete();
        return;
      }
      var packet = MidiMessage(
        data,
        DateTime.now().millisecondsSinceEpoch,
        this,
      );
      _rxStreamCtrl.add(packet);
    });

    return true;
  }

  void send(Uint8List midiMessage) {
    final buffer = calloc<Uint8>(midiMessage.lengthInBytes);
    for (var i = 0; i < midiMessage.length; i++) {
      buffer[i] = midiMessage[i];
    }
    _send(buffer, midiMessage.length);
  }

  void _send(Pointer<Uint8> buffer, int length) {
    if (outPort != null) {
      final voidBuffer = buffer.cast<Void>();

      int status;
      if ((status = alsa.snd_rawmidi_write(
            outPort!.value,
            voidBuffer,
            length,
          )) <
          0) {
        print(
          'failed to write ${alsa.snd_strerror(status).cast<Utf8>().toDartString()}',
        );
      }
    } else {
      print('outport is null');
    }
  }

  Future<void> disconnect() async {
    // Create completer to wait for isolate to confirm stop
    _isolateStoppedCompleter = Completer<void>();

    // Signal the isolate to stop - this allows it to exit its read loop
    // cleanly before we close the port
    _stopPort?.send(null);
    _stopPort = null;

    // Wait for the isolate to confirm it has stopped (it sends null when done)
    // Use a timeout to avoid hanging if something goes wrong
    if (_isolate != null) {
      try {
        await _isolateStoppedCompleter!.future.timeout(
          const Duration(milliseconds: 100),
          onTimeout: () {},
        );
      } catch (_) {
        // Ignore errors - we'll kill the isolate anyway
      }
    }
    _isolateStoppedCompleter = null;

    // Close receive ports
    receivePort?.close();
    receivePort = null;
    errorPort?.close();
    errorPort = null;

    // Kill the isolate (should already be stopped, but just in case)
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;

    // Now it's safe to close the ALSA ports since the isolate has stopped
    var status = 0;
    if (inPort != null) {
      if ((status = alsa.snd_rawmidi_drain(inPort!.value)) < 0) {
        print(
          'error: cannot drain in port $this ${stringFromNative(alsa.snd_strerror(status))}',
        );
      }
      if ((status = alsa.snd_rawmidi_close(inPort!.value)) < 0) {
        print(
          'error: cannot close in port $this ${stringFromNative(alsa.snd_strerror(status))}',
        );
      }
      inPort = null;
    }

    _connectedDevices.remove(hardwareId(cardId, deviceId));
    _disconnectStreamCtrl.add(this);

    // Close output port last
    if (outPort != null) {
      if ((status = alsa.snd_rawmidi_drain(outPort!.value)) < 0) {
        print(
          'error: cannot drain out port $this ${stringFromNative(alsa.snd_strerror(status))}',
        );
      }
      if ((status = alsa.snd_rawmidi_close(outPort!.value)) < 0) {
        print(
          'error: cannot close out port $this ${stringFromNative(alsa.snd_strerror(status))}',
        );
      }
      outPort = null;
    }

    connected = false;
  }

  Map<String, Object> get toDictionary {
    return {'name': name, 'id': cardId, 'type': type, 'connected': connected};
  }

  static List<AlsaMidiDevice> getDevices() {
    StreamController<MidiMessage> rxStreamController =
        StreamController<MidiMessage>.broadcast();
    int status;
    var card = calloc<Int>();
    card.value = -1;
    Pointer<Pointer<Char>> shortname = calloc<Pointer<Char>>();

    List<AlsaMidiDevice> devices = [];

    if ((status = alsa.snd_card_next(card)) < 0) {
      print(
        'error: cannot determine card number $card ${stringFromNative(alsa.snd_strerror(status))}',
      );
      return [];
    }
    if (card.value < 0) {
      print('error: no sound cards found');
      return [];
    }

    while (card.value >= 0) {
      Pointer<Char> name = 'hw:${card.value}'.toNativeUtf8().cast<Char>();
      Pointer<Pointer<a.snd_ctl_>> ctl = calloc<Pointer<a.snd_ctl_>>();
      Pointer<Int> device = calloc<Int>();
      device.value = -1;

      if ((status = alsa.snd_card_get_name(card.value, shortname)) < 0) {
        print(
          'error: cannot determine card shortname $card ${stringFromNative(alsa.snd_strerror(status))}',
        );
        continue;
      }
      status = alsa.snd_ctl_open(ctl, name, 0);
      if (status < 0) {
        print(
          'error: cannot open control for card number $card ${stringFromNative(alsa.snd_strerror(status))}',
        );
        continue;
      }

      do {
        status = alsa.snd_ctl_rawmidi_next_device(ctl.value, device);
        if (status < 0) {
          print(
            'error: cannot determine device number ${device.value} ${stringFromNative(alsa.snd_strerror(status))}',
          );
          break;
        }

        if (device.value >= 0) {
          var deviceId = hardwareId(card.value, device.value);
          if (!_connectedDevices.containsKey(deviceId)) {
            devices.add(
              AlsaMidiDevice(
                ctl.value,
                card.value,
                device.value,
                stringFromNative(shortname.value),
                'native',
                rxStreamController,
              ),
            );
          }
        }
      } while (device.value > 0);

      if ((status = alsa.snd_card_next(card)) < 0) {
        print(
          'error: cannot determine card number $card ${stringFromNative(alsa.snd_strerror(status))}',
        );
        break;
      }

      calloc.free(name);
      calloc.free(ctl);
      calloc.free(device);
    }

    // Add all connected devices
    devices.addAll(_connectedDevices.values);

    return devices;
  }

  static String hardwareId(int card, int device) => 'hw:$card,$device';
}
