import 'dart:convert';
import 'dart:io';

/// Small dependency-free client for a local Ollama server.
///
/// The default endpoint matches Ollama's local API. The endpoint may be
/// changed in the UI for remote/LAN Ollama instances.
class OllamaService {
  OllamaService({this.baseUrl = 'http://localhost:11434'});

  String baseUrl;

  String get _root {
    var value = baseUrl.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.endsWith('/api')) {
      value = value.substring(0, value.length - 4);
    }
    return value;
  }

  Uri _uri(String path) => Uri.parse('$_root/api/$path');

  Future<List<String>> listModels() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(_uri('tags'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OllamaException('Ollama returned HTTP ${response.statusCode}: $body');
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final raw = decoded['models'];
      if (raw is! List) return <String>[];
      final models = <String>[];
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final value = (item['name'] ?? item['model'])?.toString().trim();
          if (value != null && value.isNotEmpty) models.add(value);
        }
      }
      models.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return models;
    } on SocketException catch (e) {
      throw OllamaException('Cannot reach Ollama at $_root: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> generate({
    required String model,
    required String prompt,
    String system = '',
    bool jsonFormat = false,
  }) async {
    if (model.trim().isEmpty) {
      throw const OllamaException('Choose an Ollama model first.');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(_uri('generate'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final body = <String, dynamic>{
        'model': model.trim(),
        'prompt': prompt,
        'stream': false,
      };
      if (system.trim().isNotEmpty) body['system'] = system.trim();
      if (jsonFormat) body['format'] = 'json';
      request.write(jsonEncode(body));
      final response = await request.close().timeout(const Duration(minutes: 20));
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OllamaException(
          'Ollama returned HTTP ${response.statusCode}: $responseBody',
        );
      }
      final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
      final result = decoded['response']?.toString() ?? '';
      if (result.trim().isEmpty) {
        throw const OllamaException('Ollama returned an empty response.');
      }
      return result.trim();
    } on SocketException catch (e) {
      throw OllamaException('Cannot reach Ollama at $_root: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }
}

class OllamaException implements Exception {
  const OllamaException(this.message);
  final String message;

  @override
  String toString() => message;
}
