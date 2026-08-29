// services/piper_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/voice_model.dart';

class PiperService {
  final AudioPlayer audioPlayer = AudioPlayer();
  final Set<Process> _activeProcesses = <Process>{};

  late String exePath;
  late String modelsBaseDir;

  List<VoiceModel> availableVoices = <VoiceModel>[];

  bool isInitialized = false;

  /// Full stderr from the last GPU probe, surfaced in settings so a failure
  /// gives the user something actionable instead of a shrug.
  String gpuTestLog = '';

  int _currentPlaybackId = 0;
  int _currentRenderId = 0;
  Completer<void>? _playCompleter;

  static final RegExp _speechTest = RegExp(r'[\p{L}\p{N}]', unicode: true);

  PiperService() {
    audioPlayer.onPlayerComplete.listen((_) {
      final Completer<void>? c = _playCompleter;
      if (c != null && !c.isCompleted) c.complete();
    });
  }

  // ---------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------

  Future<void> init() async {
    final String exeDir = File(Platform.resolvedExecutable).parent.path;
    final String currentDir = Directory.current.path;
    final String exeName = Platform.isWindows ? 'piper.exe' : 'piper';

    final String prod = p.join(exeDir, 'piper', exeName);
    final String dev = p.join(currentDir, 'piper', exeName);

    if (File(prod).existsSync()) {
      exePath = prod;
      modelsBaseDir = p.join(exeDir, 'model');
    } else {
      exePath = dev;
      modelsBaseDir = p.join(currentDir, 'model');
    }

    await scanForVoices();

    if (!Platform.isWindows && File(exePath).existsSync()) {
      await Process.run('chmod', <String>['+x', exePath]);
    }

    await _clearTempAudio();
    isInitialized = true;
  }

  /// Piper resolves libonnxruntime.so through its own rpath, but ONNX Runtime
  /// dlopens the CUDA provider, cuDNN and cuBLAS through the normal linker
  /// search path. Launched from a Flutter process rather than the shipped
  /// shell wrapper, that search path is missing the piper directory, which is
  /// the most common reason --cuda silently falls back to CPU.
  Map<String, String> get _processEnvironment {
    if (Platform.isWindows) return const <String, String>{};
    final String dir = p.dirname(exePath);
    final String inherited = Platform.environment['LD_LIBRARY_PATH'] ?? '';
    final List<String> parts = <String>[dir, p.join(dir, 'lib')];
    if (inherited.isNotEmpty) parts.add(inherited);
    return <String, String>{'LD_LIBRARY_PATH': parts.join(':')};
  }

  Future<Process> _spawn(List<String> args) async {
    final Process process = await Process.start(
      exePath,
      args,
      environment: _processEnvironment,
      includeParentEnvironment: true,
    );
    _activeProcesses.add(process);
    return process;
  }

  Future<void> _clearTempAudio() async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      for (final FileSystemEntity entity in tempDir.listSync()) {
        if (entity is! File) continue;
        final String name = p.basename(entity.path);
        final bool ours = name.startsWith('chunk_') ||
            name.startsWith('export_chunk_') ||
            name.startsWith('temp_raw_audio') ||
            name.startsWith('test_gpu');
        if (ours && (name.endsWith('.wav') || name.endsWith('.tmp'))) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> scanForVoices() async {
    availableVoices = <VoiceModel>[];
    final Directory dir = Directory(modelsBaseDir);
    if (!await dir.exists()) return;

    for (final FileSystemEntity entity in await dir.list().toList()) {
      if (entity is! Directory) continue;
      for (final FileSystemEntity f in await entity.list().toList()) {
        if (f is File && f.path.toLowerCase().endsWith('.onnx')) {
          availableVoices
              .add(VoiceModel(name: p.basename(entity.path), path: f.path));
          break;
        }
      }
    }
    availableVoices.sort((VoiceModel a, VoiceModel b) => a.name.compareTo(b.name));
  }

  // ---------------------------------------------------------------------
  // GPU probe
  // ---------------------------------------------------------------------

  /// Markers that mean the CUDA provider genuinely did not load.
  /// Note what is absent: a bare "warning". ONNX Runtime logs warnings on a
  /// perfectly healthy CUDA init (arena config, provider ordering, absent
  /// TensorRT), so treating any warning as failure reports no-GPU on machines
  /// where CUDA works fine.
  static const List<String> _cudaFailureMarkers = <String>[
    'failed to create cudaexecutionprovider',
    'cudaexecutionprovider is not in available provider',
    'libcudart',
    'libcudnn',
    'libcublas',
    'cudnn64_',
    'onnxruntime_providers_cuda',
    'not compiled with cuda',
    'cuda is not available',
    'error loading',
    'cannot open shared object file',
  ];

  Future<bool> testGpuSupport(String modelPath) async {
    Process? process;
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String outFile = p.join(
        tempDir.path,
        'test_gpu_${DateTime.now().millisecondsSinceEpoch}.wav',
      );
      final File probe = File(outFile);

      process = await _spawn(<String>[
        '--model',
        modelPath,
        '--output_file',
        outFile,
        '--cuda',
      ]);

      final Future<String> stderrFuture =
          process.stderr.transform(utf8.decoder).join();
      unawaited(process.stdout.drain<void>());

      process.stdin.write('Checking acceleration.');
      await process.stdin.close();

      final int exitCode = await process.exitCode;
      _activeProcesses.remove(process);

      final String log = await stderrFuture;
      gpuTestLog = log.trim();

      final bool wroteAudio = await probe.exists() && await probe.length() > 4096;
      if (await probe.exists()) {
        try {
          await probe.delete();
        } catch (_) {}
      }

      final String lower = log.toLowerCase();
      final bool declaredFailure =
          _cudaFailureMarkers.any((String m) => lower.contains(m));

      if (declaredFailure) return false;
      return exitCode == 0 && wroteAudio;
    } catch (e) {
      gpuTestLog = 'Probe threw: $e';
      if (process != null) _activeProcesses.remove(process);
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------

  Future<void> playChunks(
    List<String> chunks, {
    required String modelPath,
    required double speed,
    required int speakerId,
    required bool useGpu,
    required void Function(int) onChunkStart,
    int startIndex = 0,
  }) async {
    _currentPlaybackId++;
    final int myId = _currentPlaybackId;
    final Directory tempDir = await getTemporaryDirectory();

    Future<String?>? prefetch;
    int prefetchIndex = -1;

    for (int i = startIndex; i < chunks.length; i++) {
      if (myId != _currentPlaybackId) break;

      final String? file = (prefetch != null && prefetchIndex == i)
          ? await prefetch
          : await _generateChunk(
              chunks[i], i, tempDir.path, modelPath, speed, speakerId, useGpu, myId);

      if (myId != _currentPlaybackId) break;

      // Start rendering the next sentence while this one plays.
      if (i + 1 < chunks.length) {
        prefetchIndex = i + 1;
        prefetch = _generateChunk(chunks[i + 1], i + 1, tempDir.path, modelPath,
            speed, speakerId, useGpu, myId);
      } else {
        prefetch = null;
        prefetchIndex = -1;
      }

      if (file == null) continue;
      if (myId != _currentPlaybackId) break;

      onChunkStart(i);
      final Completer<void> completer = Completer<void>();
      _playCompleter = completer;

      try {
        await audioPlayer.play(DeviceFileSource(file));
        await completer.future;
      } catch (e) {
        if (!completer.isCompleted) completer.complete();
      } finally {
        try {
          final File spent = File(file);
          if (await spent.exists()) await spent.delete();
        } catch (_) {}
      }
    }
  }

  Future<String?> _generateChunk(
    String text,
    int index,
    String dir,
    String modelPath,
    double speed,
    int speakerId,
    bool useGpu,
    int playbackId,
  ) async {
    if (!_speechTest.hasMatch(text)) return null;
    if (playbackId != _currentPlaybackId) return null;

    final String outFile = p.join(dir, 'chunk_${index}_$playbackId.wav');
    final File f = File(outFile);

    Process? process;
    try {
      final List<String> args = <String>[
        '--model',
        modelPath,
        '--output_file',
        outFile,
        '--length_scale',
        speed.toStringAsFixed(2),
      ];
      if (speakerId > 0) args.addAll(<String>['--speaker', speakerId.toString()]);
      if (useGpu) args.add('--cuda');

      process = await _spawn(args);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      process.stdin.write(text);
      await process.stdin.close();

      final int exitCode = await process.exitCode;
      _activeProcesses.remove(process);

      if (playbackId != _currentPlaybackId) {
        // Prefetched audio for a run that has since been stopped. Nobody will
        // play or delete this file, so clean it up here.
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
        return null;
      }
      if (exitCode == 0 && await f.exists() && await f.length() > 100) {
        return outFile;
      }
    } catch (_) {
      if (process != null) _activeProcesses.remove(process);
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------

  String _formatSrtTime(int ms) {
    final int h = ms ~/ 3600000;
    final int m = (ms % 3600000) ~/ 60000;
    final int s = (ms % 60000) ~/ 1000;
    final int milli = ms % 1000;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')},${milli.toString().padLeft(3, '0')}';
  }

  String _formatEta(int ms) {
    if (ms < 0) return '00:00';
    final int total = ms ~/ 1000;
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Walks the RIFF chunk table looking for [chunkId].
  /// Chunk bodies are padded to an even byte boundary, so an odd size must be
  /// rounded up when advancing or every chunk after it desyncs.
  int _findChunk(Uint8List b, String chunkId) {
    if (b.length < 12) return -1;
    final ByteData view = ByteData.view(b.buffer, b.offsetInBytes, b.length);
    int offset = 12;
    while (offset + 8 <= b.length) {
      final String id = String.fromCharCodes(b.sublist(offset, offset + 4));
      final int size = view.getUint32(offset + 4, Endian.little);
      if (id == chunkId) return offset;
      // getUint32 is never negative; a size past the end means a malformed
      // header, and advancing on it would spin or read out of bounds.
      if (size > b.length) return -1;
      offset += 8 + size + (size & 1);
    }
    return -1;
  }

  Future<bool> generateToFile(
    String text,
    String outputPath, {
    required String modelPath,
    required double speed,
    required int speakerId,
    required bool useGpu,
    List<String>? exportChunks,
    bool isSubtitlesRequested = false,
    void Function(int current, int total, String eta)? onProgress,
  }) async {
    final int myRender = ++_currentRenderId;
    bool cancelled() => myRender != _currentRenderId;

    // Fast path: one process, one file, no subtitle timing needed.
    if (exportChunks == null || exportChunks.isEmpty) {
      Process? process;
      try {
        final List<String> args = <String>[
          '--model',
          modelPath,
          '--output_file',
          outputPath,
          '--length_scale',
          '1.00',
        ];
        if (speakerId > 0) {
          args.addAll(<String>['--speaker', speakerId.toString()]);
        }
        if (useGpu) args.add('--cuda');

        process = await _spawn(args);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        process.stdin.write(text);
        await process.stdin.close();

        final int exitCode = await process.exitCode;
        _activeProcesses.remove(process);
        if (cancelled()) {
          await _deleteQuietly(File(outputPath));
          return false;
        }
        if (exitCode != 0) return false;
        return _applyExportLengthScale(outputPath, speed);
      } catch (_) {
        if (process != null) _activeProcesses.remove(process);
        return false;
      }
    }

    // Batch path: one piper process, every sentence pushed through
    // --json-input, then stitched here with per-sentence timing.
    final Directory tempDir = await getTemporaryDirectory();
    final int timestamp = DateTime.now().millisecondsSinceEpoch;

    final List<String> args = <String>[
      '--model',
      modelPath,
      '--json-input',
      '--length_scale',
      '1.00',
    ];
    if (speakerId > 0) args.addAll(<String>['--speaker', speakerId.toString()]);
    if (useGpu) args.add('--cuda');

    final Process process = await _spawn(args);
    unawaited(process.stdout.drain<void>());

    final int totalCount = exportChunks.length;
    final DateTime startTime = DateTime.now();
    int completedCount = 0;

    final List<String> tempWavPaths = <String>[
      for (int i = 0; i < totalCount; i++)
        p.join(tempDir.path, 'export_chunk_${timestamp}_$i.wav'),
    ];

    void report(int done) {
      if (done <= completedCount) return;
      completedCount = done.clamp(0, totalCount);
      if (onProgress == null) return;
      final int elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final double perChunk = elapsed / (completedCount > 0 ? completedCount : 1);
      final int remaining = (perChunk * (totalCount - completedCount)).toInt();
      onProgress(completedCount, totalCount, _formatEta(remaining));
    }

    // Primary progress signal: piper logs a real-time factor per utterance.
    final StreamSubscription<String> stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      if (line.contains('Real-time factor') ||
          line.contains('Failed to synthesize')) {
        report(completedCount + 1);
      }
    });

    // Fallback progress signal, in case a piper build changes its log format.
    // Counting finished wav files on disk cannot silently stall at zero.
    final Timer pollTimer =
        Timer.periodic(const Duration(milliseconds: 900), (_) {
      int seen = 0;
      for (final String path in tempWavPaths) {
        if (File(path).existsSync()) seen++;
      }
      report(seen);
    });

    for (int i = 0; i < totalCount; i++) {
      process.stdin.writeln(jsonEncode(<String, String>{
        'text': exportChunks[i],
        'output_file': tempWavPaths[i],
      }));
    }

    await process.stdin.flush();
    await process.stdin.close();
    await process.exitCode;
    _activeProcesses.remove(process);

    pollTimer.cancel();
    await stderrSub.cancel();

    if (cancelled()) {
      // A cancelled render must not leave a truncated WAV that looks finished.
      for (final String path in tempWavPaths) {
        await _deleteQuietly(File(path));
      }
      await _deleteQuietly(File(outputPath));
      return false;
    }

    // Stitch phase: trim silence, concatenate PCM, accumulate SRT cues.
    int srtIndex = 1;
    final StringBuffer srt = StringBuffer();
    final StringBuffer errorLog = StringBuffer();

    final File rawFile =
        File(p.join(tempDir.path, 'temp_raw_audio_$timestamp.tmp'));
    final IOSink rawSink = rawFile.openWrite();

    int totalDataBytes = 0;
    int? sampleRate;
    int? numChannels;
    int? bitsPerSample;
    int? byteRate;
    int? blockAlign;

    for (int i = 0; i < totalCount; i++) {
      final File chunkFile = File(tempWavPaths[i]);
      final String sourceText = exportChunks[i];

      if (!await chunkFile.exists() || await chunkFile.length() < 44) {
        errorLog.writeln('CHUNK $i: piper produced no audio. TEXT: $sourceText\n');
        continue;
      }

      final Uint8List bytes = await chunkFile.readAsBytes();
      final int fmtOffset = _findChunk(bytes, 'fmt ');
      final int dataOffset = _findChunk(bytes, 'data');

      if (fmtOffset == -1 || dataOffset == -1) {
        errorLog.writeln('CHUNK $i: no fmt/data chunk. TEXT: $sourceText\n');
        await chunkFile.delete();
        continue;
      }

      final ByteData view =
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

      if (sampleRate == null) {
        numChannels = view.getUint16(fmtOffset + 10, Endian.little);
        sampleRate = view.getUint32(fmtOffset + 12, Endian.little);
        byteRate = view.getUint32(fmtOffset + 16, Endian.little);
        blockAlign = view.getUint16(fmtOffset + 20, Endian.little);
        bitsPerSample = view.getUint16(fmtOffset + 22, Endian.little);
      }

      if (blockAlign == null || blockAlign == 0 || byteRate == null) {
        errorLog.writeln('CHUNK $i: unreadable format header.\n');
        await chunkFile.delete();
        continue;
      }

      final int declaredSize = view.getUint32(dataOffset + 4, Endian.little);
      final int available = bytes.length - (dataOffset + 8);
      int readSize = (declaredSize > 0 && declaredSize < available)
          ? declaredSize
          : available;
      readSize -= readSize % blockAlign;

      if (readSize <= 0) {
        errorLog.writeln('CHUNK $i: empty data chunk. TEXT: $sourceText\n');
        await chunkFile.delete();
        continue;
      }

      Uint8List audio = bytes.sublist(dataOffset + 8, dataOffset + 8 + readSize);

      // Trim leading and trailing silence so sentences butt up cleanly and
      // the SRT cue boundaries land on actual speech.
      if (bitsPerSample == 16 && audio.length >= blockAlign) {
        final ByteData pcm =
            ByteData.view(audio.buffer, audio.offsetInBytes, audio.length);
        const int threshold = 150;
        int firstAudible = 0;
        int lastAudible = audio.length - blockAlign;
        if (lastAudible < 0) lastAudible = 0;

        for (int j = 0; j <= audio.length - blockAlign; j += blockAlign) {
          if (pcm.getInt16(j, Endian.little).abs() > threshold) {
            firstAudible = j;
            break;
          }
        }
        for (int j = audio.length - blockAlign; j >= firstAudible; j -= blockAlign) {
          if (pcm.getInt16(j, Endian.little).abs() > threshold) {
            lastAudible = j;
            break;
          }
        }

        int pad = (byteRate * 0.05).toInt();
        pad -= pad % blockAlign;
        firstAudible = (firstAudible - pad).clamp(0, audio.length);
        lastAudible = (lastAudible + pad).clamp(0, audio.length - blockAlign);

        if (lastAudible >= firstAudible) {
          audio = audio.sublist(firstAudible, lastAudible + blockAlign);
          int minBytes = (byteRate * 0.05).toInt();
          minBytes -= minBytes % blockAlign;
          if (audio.length < minBytes) audio = Uint8List(0);
        } else {
          audio = Uint8List(0);
        }
      }

      if (audio.isEmpty) {
        errorLog.writeln('CHUNK $i: trimmed to silence. TEXT: $sourceText\n');
        await chunkFile.delete();
        continue;
      }

      final int startBytes = totalDataBytes;
      rawSink.add(audio);
      totalDataBytes += audio.length;

      // Piper is rendered at native 1.0 timing. The completed WAV is then
      // time-scaled as one continuous file. Scale cue positions by the same
      // length factor so subtitles stay locked to the post-processed audio.
      final int startMs = (((startBytes * 1000) / byteRate) * speed).round();
      final int endMs = (((totalDataBytes * 1000) / byteRate) * speed).round();
      int displayEnd = endMs - 15;
      if (displayEnd <= startMs) displayEnd = startMs + 10;

      srt.writeln(srtIndex++);
      srt.writeln('${_formatSrtTime(startMs)} --> ${_formatSrtTime(displayEnd)}');
      srt.writeln(sourceText.trim().replaceAll(RegExp(r'\s+'), ' '));
      srt.writeln();

      await chunkFile.delete();
    }

    await rawSink.flush();
    await rawSink.close();

    bool tempoOk = true;
    if (sampleRate != null && totalDataBytes > 0) {
      final IOSink finalSink = File(outputPath).openWrite();
      finalSink.add(_wavHeader(
        dataBytes: totalDataBytes,
        numChannels: numChannels!,
        sampleRate: sampleRate,
        byteRate: byteRate!,
        blockAlign: blockAlign!,
        bitsPerSample: bitsPerSample!,
      ));
      await finalSink.addStream(rawFile.openRead());
      await finalSink.flush();
      await finalSink.close();

      // Do not ask Piper to reinterpret speed for every sentence. Render the
      // narration at 1.0, stitch it, and change tempo once on the completed
      // waveform. FFmpeg's atempo changes duration without changing pitch.
      tempoOk = await _applyExportLengthScale(outputPath, speed);

      if (tempoOk && isSubtitlesRequested) {
        String srtPath =
            outputPath.replaceAll(RegExp(r'\.wav$', caseSensitive: false), '.srt');
        if (srtPath == outputPath) srtPath += '.srt';
        await File(srtPath).writeAsString(srt.toString());
      }

      if (errorLog.isNotEmpty) {
        String logPath = outputPath.replaceAll(
            RegExp(r'\.wav$', caseSensitive: false), '_errors.log');
        if (logPath == outputPath) logPath += '_errors.log';
        await File(logPath).writeAsString(
          'NODE WRITER TTS GENERATION ERRORS\n'
          '===========================\n\n${errorLog.toString()}',
        );
      }
    }

    if (await rawFile.exists()) await rawFile.delete();
    return totalDataBytes > 0 && tempoOk;
  }

  /// Applies the UI's Piper-style length scale to the completed export.
  ///
  /// The VOICE panel currently uses length-scale semantics: values below 1.0
  /// are faster and values above 1.0 are slower. FFmpeg's atempo uses the
  /// opposite convention (a value above 1.0 is faster), so tempo = 1 / scale.
  /// Doing this once after stitching guarantees that every sentence has the
  /// same final speed and avoids sentence/chunk synthesis differences.
  Future<bool> _applyExportLengthScale(
    String outputPath,
    double lengthScale,
  ) async {
    if ((lengthScale - 1.0).abs() < 0.0001) {
      final File file = File(outputPath);
      return await file.exists() && await file.length() > 44;
    }
    if (!lengthScale.isFinite || lengthScale <= 0) return false;

    final File source = File(outputPath);
    if (!await source.exists() || await source.length() <= 44) return false;

    final double tempo = 1.0 / lengthScale;
    final String tempPath = p.join(
      p.dirname(outputPath),
      '.${p.basenameWithoutExtension(outputPath)}_tempo_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    final File temp = File(tempPath);

    try {
      final ProcessResult result = await Process.run(
        'ffmpeg',
        <String>[
          '-hide_banner',
          '-loglevel',
          'error',
          '-nostdin',
          '-y',
          '-i',
          outputPath,
          '-filter:a',
          'atempo=${tempo.toStringAsFixed(8)}',
          '-c:a',
          'pcm_s16le',
          tempPath,
        ],
      );

      if (result.exitCode != 0 ||
          !await temp.exists() ||
          await temp.length() <= 44) {
        await _deleteQuietly(temp);
        return false;
      }

      await _deleteQuietly(source);
      await temp.rename(outputPath);
      return true;
    } catch (_) {
      await _deleteQuietly(temp);
      return false;
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Uint8List _wavHeader({
    required int dataBytes,
    required int numChannels,
    required int sampleRate,
    required int byteRate,
    required int blockAlign,
    required int bitsPerSample,
  }) {
    final ByteData h = ByteData(44);
    void ascii(int offset, String tag) {
      for (int i = 0; i < 4; i++) {
        h.setUint8(offset + i, tag.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    h.setUint32(4, dataBytes + 36, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, numChannels, Endian.little);
    h.setUint32(24, sampleRate, Endian.little);
    h.setUint32(28, byteRate, Endian.little);
    h.setUint16(32, blockAlign, Endian.little);
    h.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    h.setUint32(40, dataBytes, Endian.little);
    return h.buffer.asUint8List();
  }

  // ---------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------

  /// Stops playback and cancels an in-flight render.
  Future<void> stop() async {
    _currentPlaybackId++;
    _currentRenderId++;
    for (final Process process in _activeProcesses.toList()) {
      process.kill();
    }
    _activeProcesses.clear();
    await audioPlayer.stop();
    final Completer<void>? c = _playCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  void dispose() {
    unawaited(stop());
    audioPlayer.dispose();
  }
}