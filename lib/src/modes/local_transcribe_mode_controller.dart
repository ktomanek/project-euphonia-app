import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:video_player/video_player.dart';

import '../repos/settings_repository.dart';
import 'local_transcribe_mode_view.dart';

class LocalTranscribeModeController extends StatefulWidget {
  const LocalTranscribeModeController({super.key});

  @override
  State<LocalTranscribeModeController> createState() =>
      _LocalTranscribeModeControllerState();
}

class _LocalTranscribeModeControllerState
    extends State<LocalTranscribeModeController> {
  late final AudioRecorder record;
  late VideoPlayerController _playerController;
  var _phrase = '';
  var _isRecording = false;
  var _isPlaying = false;
  var _canPlay = false;
  var _uploadStatus = UploadStatus.notStarted;

  bool _isSherpaInitialized = false;

  sherpa_onnx.OfflineRecognizer? _recognizer;
  sherpa_onnx.OfflineStream? _stream;
  String _last = '';

  @override
  void initState() {
    record = AudioRecorder();
    super.initState();
  }

  void _manageRecording() async {
    if (_isRecording) {
      await _stopRecording();
      setState(() {
        _isRecording = false;
      });
    } else {
      await _startRecording();
      setState(() {
        _isRecording = true;
      });
    }
  }

  Future<String> _getRecordingPath() {
    return getApplicationDocumentsDirectory().then(
      (value) => '${value.path}/recording.wav',
    );
  }

  Future<void> _startRecording() async {
    var path = await _getRecordingPath();
    if (await record.hasPermission()) {
      await record.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: path,
      );
    }
  }

  Future<void> _preparePlayerForFile({required File audioFile}) async {
    _playerController = VideoPlayerController.file(audioFile);
    _playerController.initialize().then((_) {});
    _playerController.addListener(() {
      setState(() {
        _isPlaying = _playerController.value.isPlaying;
      });
    });
  }

  Future<void> _transcribe({required String audioFile}) async {
    setState(() {
      _uploadStatus = UploadStatus.started;
    });
    if (!_isSherpaInitialized) {
      sherpa_onnx.initBindings();
      _recognizer = sherpa_onnx.OfflineRecognizer(
          sherpa_onnx.OfflineRecognizerConfig(
              model: sherpa_onnx.OfflineModelConfig(
                  moonshine: sherpa_onnx.OfflineMoonshineModelConfig(
                      preprocessor:
                          await copyAssetFile(
                              'assets/moonshine-tiny/preprocess.onnx'),
                      encoder:
                          await copyAssetFile(
                              'assets/moonshine-tiny/encode.int8.onnx'),
                      cachedDecoder: await copyAssetFile(
                          'assets/moonshine-tiny/cached_decode.int8.onnx'),
                      uncachedDecoder: await copyAssetFile(
                          'assets/moonshine-tiny/uncached_decode.int8.onnx')),
                  tokens: await copyAssetFile(
                      'assets/moonshine-tiny/tokens.txt'))));
      _stream = _recognizer?.createStream();
      _isSherpaInitialized = true;
    }
    try {
      const encoder = AudioEncoder.pcm16bits;

      if (!await _isEncoderSupported(encoder)) {
        return;
      }

      final wavData = sherpa_onnx.readWave(audioFile);

      _stream!.acceptWaveform(
          samples: wavData.samples, sampleRate: wavData.sampleRate);

      _recognizer!.decode(_stream!);

      final text = _recognizer!.getResult(_stream!).text;

      var textToDisplay = _last;
      if (text.isNotEmpty) {
        if (_last.isEmpty) {
          textToDisplay = text;
        } else {
          textToDisplay = '$text\n\n$_last';
        }
      }
      setState(() {
        _phrase = textToDisplay;
      });
    } catch (e) {
      developer.log(e.toString());
      setState(() {
        _phrase = 'ERROR: ${e.toString()}';
      });
    } finally {
      setState(() {
        _uploadStatus = UploadStatus.completed;
      });
    }
  }

  void _playRecording() async {
    if (_isPlaying) {
      _playerController.pause();
      setState(() {
        _isPlaying = false;
      });
    } else {
      await _playerController.play();
      setState(() {
        _isPlaying = true;
      });
    }
  }

  Future<bool> _checkIfRecordingFileIsAvailable() async {
    var recordingFile = File(await _getRecordingPath());
    setState(() {
      _canPlay = recordingFile.existsSync();
    });
    return _canPlay;
  }

  Future<void> _stopRecording() async {
    var _ = await record.stop();
    Future.wait([_checkIfRecordingFileIsAvailable(), _getRecordingPath()]).then(
      (results) {
        final bool fileExists = results[0] as bool;
        final String filePath = results[1] as String;
        if (fileExists) {
          _preparePlayerForFile(audioFile: File(filePath));
          _transcribe(audioFile: filePath);
        }
      },
    );
  }

  Future<bool> _isEncoderSupported(AudioEncoder encoder) async {
    final isSupported = await record.isEncoderSupported(encoder);

    if (!isSupported) {
      developer.log('${encoder.name} is not supported on this platform.');
      developer.log('Supported encoders are:');

      for (final e in AudioEncoder.values) {
        if (await record.isEncoderSupported(e)) {
          developer.log('- ${encoder.name}');
        }
      }
    }

    return isSupported;
  }

  Future<String> copyAssetFile(String src, [String? dst]) async {
    final Directory directory = await getApplicationDocumentsDirectory();
    dst ??= basename(src);
    final target = join(directory.path, dst);
    bool exists = await File(target).exists();

    final data = await rootBundle.load(src);

    if (!exists || File(target).lengthSync() != data.lengthInBytes) {
      final List<int> bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await File(target).writeAsBytes(bytes);
    }

    return target;
  }

  @override
  void dispose() {
    _recognizer?.free();
    _stream?.free();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsRepository>(
        builder: (context, settings, _) => LocalTranscribeModeView(
              phrase: _phrase.trim(),
              record: _isPlaying ? null : _manageRecording,
              isRecording: _isRecording,
              play: _canPlay && !_isRecording ? _playRecording : null,
              isPlaying: _isPlaying,
              isRecorded: _canPlay,
              uploadStatus: _uploadStatus,
            ));
  }
}
