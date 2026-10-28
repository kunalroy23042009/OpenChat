import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../chat_store.dart';
import '../media/chat_media.dart';
import '../media/encrypted_media_index.dart';

class EncryptedMediaBrowser extends StatefulWidget {
  const EncryptedMediaBrowser({
    super.key,
    required this.store,
    required this.client,
  });

  final ChatStore store;
  final SupabaseClient client;

  @override
  State<EncryptedMediaBrowser> createState() => _EncryptedMediaBrowserState();
}

class _EncryptedMediaBrowserState extends State<EncryptedMediaBrowser> {
  late final EncryptedMediaIndex _index;
  late final ChatMedia _chatMedia;
  bool _loading = true;
  String _filter = 'all'; // all, images, videos, voice, documents
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _chatMedia = ChatMedia(widget.client);
    _index = EncryptedMediaIndex(widget.store, _chatMedia);
    _buildIndex();
  }

  Future<void> _buildIndex() async {
    setState(() => _loading = true);
    await _index.buildIndex();
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _index.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Media'),
        actions: [
          if (!_loading)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh index',
              onPressed: _buildIndex,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Search bar
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search media...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF2A3942) : Colors.grey[100],
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),

                // Filter chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      _FilterChip(
                        label: 'All',
                        selected: _filter == 'all',
                        onTap: () => setState(() => _filter = 'all'),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Images',
                        selected: _filter == 'images',
                        onTap: () => setState(() => _filter = 'images'),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Videos',
                        selected: _filter == 'videos',
                        onTap: () => setState(() => _filter = 'videos'),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Voice',
                        selected: _filter == 'voice',
                        onTap: () => setState(() => _filter = 'voice'),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Documents',
                        selected: _filter == 'documents',
                        onTap: () => setState(() => _filter = 'documents'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                // Stats
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        '${_index.totalCount} media files',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Last updated: ${_index.lastRefresh?.toLocal().toString().substring(0, 16) ?? 'never'}',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                // Media grid
                Expanded(
                  child: _buildMediaGrid(),
                ),
              ],
            ),
    );
  }

  Widget _buildMediaGrid() {
    final items = _getFilteredItems();
    
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isEmpty ? 'No media found' : 'No results for "$_searchQuery"',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Encrypted media from your chats will appear here',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _MediaGridItem(
          item: item,
          onTap: () => _openMediaPreview(item),
          chatMedia: _chatMedia,
        );
      },
    );
  }

  List<EncryptedMediaItem> _getFilteredItems() {
    List<EncryptedMediaItem> items = [];
    
    if (_searchQuery.isNotEmpty) {
      items = _index.search(_searchQuery);
    } else {
      switch (_filter) {
        case 'all':
          for (final typeItems in _index.byType.values) {
            items.addAll(typeItems);
          }
          break;
        case 'images':
          items = _index.getMediaByType(MediaType.image);
          break;
        case 'videos':
          items = _index.getMediaByType(MediaType.video);
          break;
        case 'voice':
          items = _index.getMediaByType(MediaType.voice);
          break;
        case 'documents':
          items = _index.getMediaByType(MediaType.document);
          break;
      }
    }

    // Sort by newest first
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return items;
  }

  Future<void> _openMediaPreview(EncryptedMediaItem item) async {
    if (item.type == MediaType.image) {
      await _showImagePreview(item);
    } else if (item.type == MediaType.video) {
      await _showVideoPreview(item);
    } else if (item.type == MediaType.voice) {
      await _showVoicePreview(item);
    } else if (item.type == MediaType.document) {
      await _showDocumentPreview(item);
    }
  }

  Future<void> _showImagePreview(EncryptedMediaItem item) async {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            FutureBuilder<Uint8List?>(
              future: _index.decryptMedia(item),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Container(
                    constraints: const BoxConstraints(maxWidth: 300, maxHeight: 400),
                    child: const Center(child: CircularProgressIndicator()),
                  );
                }
                if (!snapshot.hasData || snapshot.data == null) {
                  return Container(
                    constraints: const BoxConstraints(maxWidth: 300, maxHeight: 400),
                    color: Colors.black87,
                    child: const Center(
                      child: Text('Failed to load image', style: TextStyle(color: Colors.white)),
                    ),
                  );
                }
                return ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    snapshot.data!,
                    fit: BoxFit.contain,
                  ),
                );
              },
            ),
            Positioned(
              top: 8,
              right: 8,
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showVideoPreview(EncryptedMediaItem item) async {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          alignment: Alignment.center,
          children: [
            FutureBuilder<Uint8List?>(
              future: _index.decryptVideo(item),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Container(
                    constraints: const BoxConstraints(maxWidth: 400, maxHeight: 300),
                    color: Colors.black87,
                    child: const Center(child: CircularProgressIndicator()),
                  );
                }
                if (!snapshot.hasData || snapshot.data == null) {
                  return Container(
                    constraints: const BoxConstraints(maxWidth: 400, maxHeight: 300),
                    color: Colors.black87,
                    child: const Center(
                      child: Text('Failed to load video', style: TextStyle(color: Colors.white)),
                    ),
                  );
                }
                // Save to temp file and play
                return _VideoPlayerDialog(
                  bytes: snapshot.data!,
                  caption: item.caption,
                );
              },
            ),
            Positioned(
              top: 8,
              right: 8,
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showVoicePreview(EncryptedMediaItem item) async {
    final bytes = await _index.decryptMedia(item);
    if (bytes == null || !mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.caption),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.mic, size: 64, color: Color(0xFF00A884)),
            const SizedBox(height: 16),
            Text('Duration: ${item.durationSec}s'),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play (requires audio player)'),
              onPressed: () {
                // Would need audio player integration
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDocumentPreview(EncryptedMediaItem item) async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.fileName ?? 'Document'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.description, size: 64, color: Color(0xFF00A884)),
            const SizedBox(height: 16),
            if (item.fileSize != null)
              Text('Size: ${_formatFileSize(item.fileSize!)}'),
            const SizedBox(height: 8),
            Text('From: ${item.peerName}'),
            Text('Date: ${item.displayDate}'),
            const SizedBox(height: 16),
            Text('Document preview requires file opener integration'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: isDark ? const Color(0xFF00A884).withValues(alpha: 0.2) : const Color(0xFFE8F5E9),
      checkmarkColor: const Color(0xFF00A884),
      labelStyle: TextStyle(
        color: selected ? const Color(0xFF00A884) : (isDark ? Colors.white70 : Colors.black54),
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
      side: BorderSide(
        color: selected ? const Color(0xFF00A884) : (isDark ? Colors.white24 : Colors.black12),
      ),
      backgroundColor: isDark ? const Color(0xFF1F2C34) : Colors.white,
    );
  }
}

class _MediaGridItem extends StatelessWidget {
  const _MediaGridItem({
    required this.item,
    required this.onTap,
    required this.chatMedia,
  });

  final EncryptedMediaItem item;
  final VoidCallback onTap;
  final ChatMedia chatMedia;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2A3942) : Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Media thumbnail/type indicator
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1F2C34) : Colors.grey[200],
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: _buildThumbnail(isDark),
              ),
            ),
            
            // Info
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _getTypeIcon(),
                        size: 14,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          item.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.displayDate,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(bool isDark) {
    
    switch (item.type) {
      case MediaType.image:
        // For encrypted images, we show a placeholder with the path
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF00A884).withValues(alpha: 0.3),
                    const Color(0xFF00897B).withValues(alpha: 0.3),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            const Center(
              child: Icon(Icons.image, size: 48, color: Colors.white),
            ),
          ],
        );
      case MediaType.video:
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.purple.withValues(alpha: 0.3),
                    Colors.deepPurple.withValues(alpha: 0.3),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            const Center(
              child: Icon(Icons.videocam, size: 48, color: Colors.white),
            ),
          ],
        );
      case MediaType.voice:
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.orange.withValues(alpha: 0.3),
                    Colors.deepOrange.withValues(alpha: 0.3),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            const Center(
              child: Icon(Icons.mic, size: 48, color: Colors.white),
            ),
          ],
        );
      case MediaType.document:
        return Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.blue.withValues(alpha: 0.3),
                    Colors.indigo.withValues(alpha: 0.3),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
            const Center(
              child: Icon(Icons.description, size: 48, color: Colors.white),
            ),
          ],
        );
    }
  }

  IconData _getTypeIcon() {
    switch (item.type) {
      case MediaType.image: return Icons.image;
      case MediaType.video: return Icons.videocam;
      case MediaType.voice: return Icons.mic;
      case MediaType.document: return Icons.description;
    }
  }
}

class _VideoPlayerDialog extends StatefulWidget {
  const _VideoPlayerDialog({required this.bytes, required this.caption});
  final Uint8List bytes;
  final String caption;

  @override
  State<_VideoPlayerDialog> createState() => _VideoPlayerDialogState();
}

class _VideoPlayerDialogState extends State<_VideoPlayerDialog> {
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 300),
      color: Colors.black87,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.videocam, size: 64, color: Colors.white70),
                  const SizedBox(height: 16),
                  Text(
                    'Video decrypted (${(widget.bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Video player integration needed',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(widget.caption, style: const TextStyle(color: Colors.white)),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}