import 'package:flutter/material.dart';

enum MediaAttachmentType {
  image,
  audio,
  video,
  document,
}

class MediaAttachment {
  const MediaAttachment({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.type,
    this.url,
    this.localPath,
    this.mimeType,
  });

  final String id;
  final String fileName;
  final int sizeBytes;
  final MediaAttachmentType type;
  final String? url;
  final String? localPath;
  final String? mimeType;

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class MediaPreviewCard extends StatefulWidget {
  const MediaPreviewCard({
    super.key,
    required this.attachment,
    this.onTapDownload,
  });

  final MediaAttachment attachment;
  final VoidCallback? onTapDownload;

  @override
  State<MediaPreviewCard> createState() => _MediaPreviewCardState();
}

class _MediaPreviewCardState extends State<MediaPreviewCard> {
  bool isPlaying = false;
  double audioProgress = 0.3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    switch (widget.attachment.type) {
      case MediaAttachmentType.image:
        return GestureDetector(
          onTap: () => _openLightbox(context),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 220, maxWidth: 280),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.attachment.url != null)
                  Image.network(
                    widget.attachment.url!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => _buildPlaceholderIcon(Icons.image),
                  )
                else
                  _buildPlaceholderIcon(Icons.image_outlined),
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.attachment.formattedSize,
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

      case MediaAttachmentType.audio:
        return Container(
          width: 260,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
            ),
          ),
          child: Row(
            children: [
              IconButton.filledTonal(
                icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () {
                  setState(() => isPlaying = !isPlaying);
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.attachment.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SliderTheme(
                      data: SliderThemeData(
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        trackHeight: 4,
                        activeTrackColor: theme.colorScheme.primary,
                        inactiveTrackColor: isDark ? Colors.white24 : Colors.black12,
                      ),
                      child: Slider(
                        value: audioProgress,
                        onChanged: (val) {
                          setState(() => audioProgress = val);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      case MediaAttachmentType.video:
        return Container(
          width: 260,
          height: 150,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFF1E293B),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.movie_outlined, size: 48, color: Colors.white54),
              IconButton.filled(
                iconSize: 32,
                icon: const Icon(Icons.play_arrow),
                onPressed: widget.onTapDownload,
              ),
              Positioned(
                bottom: 8,
                left: 12,
                right: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        widget.attachment.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                    Text(
                      widget.attachment.formattedSize,
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      case MediaAttachmentType.document:
        return Container(
          width: 260,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.insert_drive_file, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.attachment.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.attachment.formattedSize,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.download_rounded),
                onPressed: widget.onTapDownload,
              ),
            ],
          ),
        );
    }
  }

  Widget _buildPlaceholderIcon(IconData icon) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: Colors.grey),
          const SizedBox(height: 4),
          Text(widget.attachment.fileName, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  void _openLightbox(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              child: widget.attachment.url != null
                  ? Image.network(widget.attachment.url!)
                  : _buildPlaceholderIcon(Icons.image),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
