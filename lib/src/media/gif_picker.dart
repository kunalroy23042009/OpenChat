import 'package:flutter/material.dart';

import 'gif_search.dart';

/// Explicit GIF search UI. It does not contact Giphy until the user searches.
class GifPickerSheet extends StatefulWidget {
  const GifPickerSheet({super.key, this.service});

  final GifSearchService? service;

  @override
  State<GifPickerSheet> createState() => _GifPickerSheetState();
}

class _GifPickerSheetState extends State<GifPickerSheet> {
  final _query = TextEditingController();
  late final GifSearchService _service = widget.service ?? GifSearchService();
  var _results = const <GifSearchResult>[];
  var _loading = false;
  var _request = 0;
  String? _error;

  Future<void> _search() async {
    final query = _query.text.trim();
    final request = ++_request;
    if (query.length < 2) {
      setState(() => _error = 'Enter at least two characters.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await _service.search(query);
      if (!mounted || request != _request) return;
      setState(() => _results = results);
    } on ArgumentError catch (error) {
      if (mounted && request == _request) {
        setState(() => _error = error.message.toString());
      }
    } on StateError catch (error) {
      if (mounted && request == _request) {
        setState(() => _error = error.message.toString());
      }
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = 'GIF search failed. Check your connection.');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configured = _service.isConfigured;
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.82,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.gif_box_outlined),
                  const SizedBox(width: 8),
                  Text(
                    'GIF search',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close GIF search',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (!configured)
                const Expanded(
                  child: Center(
                    child: Text(
                      'GIF search needs a GIPHY_API_KEY build define. Add it to config.json, then rebuild the app.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              else ...[
                TextField(
                  controller: _query,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: 'Search Giphy',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: 'Search GIFs',
                      onPressed: _loading ? null : _search,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_loading) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Expanded(
                  child: _results.isEmpty
                      ? Center(
                          child: Text(
                            _loading
                                ? 'Searching Giphy…'
                                : 'Search for a GIF to send.',
                          ),
                        )
                      : GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                                childAspectRatio: 0.9,
                              ),
                          itemCount: _results.length,
                          itemBuilder: (context, index) {
                            final gif = _results[index];
                            return Semantics(
                              button: true,
                              label: 'Send GIF: ${gif.title}',
                              child: InkWell(
                                onTap: () => Navigator.pop(context, gif),
                                borderRadius: BorderRadius.circular(12),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.network(
                                    gif.previewUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => const ColoredBox(
                                      color: Colors.black12,
                                      child: Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const Text(
                  'Search terms and previews are sent to Giphy. The selected GIF is encrypted before it is sent in chat.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
