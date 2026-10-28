import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_chat/src/media/gif_search.dart';

void main() {
  test('search requires an explicitly configured public key', () async {
    final service = GifSearchService(apiKey: '');
    await expectLater(service.search('cat'), throwsStateError);
    service.dispose();
  });

  test('search parses HTTPS previews and original GIF URLs', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'api.giphy.com');
      expect(request.url.queryParameters['api_key'], 'public-key');
      expect(request.url.queryParameters['q'], 'happy cat');
      return http.Response(
        jsonEncode({
          'data': [
            {
              'id': 'good',
              'title': 'Happy cat',
              'images': {
                'fixed_width': {'url': 'https://media.giphy.com/preview.gif'},
                'original': {'url': 'https://media.giphy.com/original.gif'},
              },
            },
            {
              'id': 'bad',
              'images': {
                'fixed_width': {'url': 'http://media.giphy.com/preview.gif'},
                'original': {'url': 'https://media.giphy.com/original.gif'},
              },
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = GifSearchService(client: client, apiKey: 'public-key');

    final results = await service.search('happy cat');

    expect(results, hasLength(1));
    expect(results.single.id, 'good');
    expect(results.single.title, 'Happy cat');
    service.dispose();
  });

  test('download accepts a bounded GIF and rejects oversized data', () async {
    final gif = const GifSearchResult(
      id: 'gif',
      title: 'GIF',
      previewUrl: 'https://media.giphy.com/preview.gif',
      originalUrl: 'https://media.giphy.com/original.gif',
    );
    final service = GifSearchService(
      client: MockClient(
        (_) async => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/gif'},
        ),
      ),
      apiKey: 'public-key',
    );
    expect(await service.download(gif), [1, 2, 3]);
    service.dispose();

    final oversized = GifSearchService(
      client: MockClient(
        (_) async => http.Response.bytes(
          const [],
          200,
          headers: {
            'content-type': 'image/gif',
            'content-length': '${GifSearchService.maxDownloadBytes + 1}',
          },
        ),
      ),
      apiKey: 'public-key',
    );
    await expectLater(oversized.download(gif), throwsStateError);
    oversized.dispose();
  });
}
