import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A Giphy result containing a small preview and the original GIF bytes.
class GifSearchResult {
  const GifSearchResult({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.originalUrl,
  });

  final String id;
  final String title;
  final String previewUrl;
  final String originalUrl;
}

/// Searches Giphy with a public, build-time client key. Search requests are
/// intentionally opt-in from the picker; only the selected GIF is sealed and
/// sent through OpenChat.
class GifSearchService {
  GifSearchService({http.Client? client, String? apiKey})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _apiKey = apiKey ?? const String.fromEnvironment('GIPHY_API_KEY');

  static const maxDownloadBytes = 10 * 1024 * 1024;

  final http.Client _client;
  final bool _ownsClient;
  final String _apiKey;

  bool get isConfigured => _apiKey.trim().isNotEmpty;

  Future<List<GifSearchResult>> search(String query) async {
    final cleanQuery = query.trim();
    if (!isConfigured) {
      throw StateError('GIF search is not configured for this build.');
    }
    if (cleanQuery.length < 2 || cleanQuery.length > 200) {
      throw ArgumentError('Enter a search between 2 and 200 characters.');
    }

    final uri = Uri.https('api.giphy.com', '/v1/gifs/search', {
      'api_key': _apiKey,
      'q': cleanQuery,
      'limit': '24',
      'rating': 'pg-13',
      'lang': 'en',
    });
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('GIF search is unavailable. Try again later.');
    }
    final payload = jsonDecode(response.body);
    if (payload is! Map || payload['data'] is! List) {
      throw StateError('GIF search returned an invalid response.');
    }

    final results = <GifSearchResult>[];
    for (final item in payload['data'] as List) {
      if (item is! Map || results.length == 24) continue;
      final images = item['images'];
      if (images is! Map) continue;
      final preview = _httpsUrl((images['fixed_width'] as Map?)?['url']);
      final original = _httpsUrl((images['original'] as Map?)?['url']);
      if (preview == null || original == null) continue;
      final id = item['id'];
      if (id is! String || id.isEmpty) continue;
      final rawTitle = item['title'];
      final title = rawTitle is String ? rawTitle.trim() : '';
      results.add(
        GifSearchResult(
          id: id,
          title: title.isEmpty
              ? 'GIF'
              : title.length <= 160
              ? title
              : title.substring(0, 160),
          previewUrl: preview,
          originalUrl: original,
        ),
      );
    }
    return results;
  }

  Future<Uint8List> download(GifSearchResult result) async {
    final uri = Uri.tryParse(result.originalUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError('GIF source must use HTTPS.');
    }
    final response = await _client
        .send(http.Request('GET', uri))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('Could not download this GIF.');
    }
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (!contentType.startsWith('image/gif')) {
      throw StateError('The selected item is not a GIF.');
    }
    final contentLength = int.tryParse(
      response.headers['content-length'] ?? '',
    );
    if (contentLength != null && contentLength > maxDownloadBytes) {
      throw StateError('GIFs must be 10 MB or smaller.');
    }

    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxDownloadBytes) {
        throw StateError('GIFs must be 10 MB or smaller.');
      }
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) {
      throw StateError('Could not download this GIF.');
    }
    return Uint8List.fromList(bytes);
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }

  static String? _httpsUrl(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri.toString();
  }
}
