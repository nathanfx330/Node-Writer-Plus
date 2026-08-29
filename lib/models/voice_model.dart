// models/voice_model.dart

class VoiceModel {
  final String name;
  final String path;

  const VoiceModel({required this.name, required this.path});

  /// Piper voices are conventionally named lang_REGION-voice-quality.
  /// Split that into something readable for the settings dropdown.
  String get displayName {
    final List<String> parts = name.split('-');
    if (parts.length < 2) return name;
    return parts.sublist(1).join(' ');
  }

  String get locale {
    final int dash = name.indexOf('-');
    return dash > 0 ? name.substring(0, dash) : '';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is VoiceModel && other.path == path;

  @override
  int get hashCode => path.hashCode;
}
