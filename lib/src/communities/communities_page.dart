import 'package:flutter/material.dart';

class CommunitiesPage extends StatelessWidget {
  const CommunitiesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Communities',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'QR code',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Community QR code scanner')),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More options',
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (context) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.search),
                      title: const Text('Search communities'),
                      onTap: () => Navigator.pop(context),
                    ),
                    ListTile(
                      leading: const Icon(Icons.settings_outlined),
                      title: const Text('Community settings'),
                      onTap: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          // New Community Tile
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF2A3942)
                        : const Color(0xFFE9EDEF),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.groups, color: Colors.grey, size: 28),
                ),
                Positioned(
                  bottom: -2,
                  right: -2,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Color(0xFF00A884),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: const Icon(Icons.add, size: 16, color: Colors.white),
                  ),
                ),
              ],
            ),
            title: const Text(
              'New community',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            onTap: () {
              showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Start your community'),
                  content: const Text(
                    'Communities bring members together in topic-based groups, '
                    'and make it easy to get admin announcements. Any member can see groups and join them.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00A884),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Community created! Add groups to begin.',
                            ),
                          ),
                        );
                      },
                      child: const Text('Get started'),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(thickness: 8, height: 8),

          // Community 1: OpenChat Community
          _CommunitySection(
            name: 'OpenChat Global Community',
            avatarText: 'OC',
            groups: const [
              _CommunityGroup(
                name: 'Announcements',
                lastMessage:
                    'Welcome everyone! Signal Protocol E2EE is active.',
                time: 'Yesterday',
                isAnnouncement: true,
              ),
              _CommunityGroup(
                name: 'Flutter & Security Devs',
                lastMessage: 'Taylor: Check out the new WhatsApp UI theme!',
                time: '11:42 AM',
                unreadCount: 3,
              ),
              _CommunityGroup(
                name: 'General Discussion',
                lastMessage: 'Alex: Real-time messaging works smoothly.',
                time: '10:15 AM',
              ),
            ],
          ),

          const Divider(thickness: 8, height: 8),

          // Community 2: AI & LLM Assistants Hub
          _CommunitySection(
            name: 'AI Assistants Hub',
            avatarText: 'AI',
            groups: const [
              _CommunityGroup(
                name: 'Announcements',
                lastMessage:
                    'ChatGPT, Claude, and Gemini are now ready to chat!',
                time: '2 days ago',
                isAnnouncement: true,
              ),
              _CommunityGroup(
                name: 'Prompt Engineers',
                lastMessage: 'Sam: Haiku model response times are sub-second.',
                time: 'Yesterday',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommunitySection extends StatelessWidget {
  const _CommunitySection({
    required this.name,
    required this.avatarText,
    required this.groups,
  });

  final String name;
  final String avatarText;
  final List<_CommunityGroup> groups;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF00A884),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(
              avatarText,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          title: Text(
            name,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        const Divider(height: 1),
        for (final group in groups) ...[
          ListTile(
            leading: CircleAvatar(
              backgroundColor: group.isAnnouncement
                  ? const Color(0xFF00A884).withValues(alpha: 0.15)
                  : Colors.grey.withValues(alpha: 0.2),
              child: Icon(
                group.isAnnouncement ? Icons.campaign : Icons.group,
                color: group.isAnnouncement
                    ? const Color(0xFF00A884)
                    : Colors.grey,
                size: 22,
              ),
            ),
            title: Text(
              group.name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
            subtitle: Text(
              group.lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  group.time,
                  style: TextStyle(
                    fontSize: 11,
                    color: group.unreadCount > 0
                        ? const Color(0xFF00A884)
                        : Colors.grey,
                  ),
                ),
                if (group.unreadCount > 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFF00A884),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${group.unreadCount}',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ],
              ],
            ),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Opened community group: ${group.name}'),
                ),
              );
            },
          ),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: InkWell(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Viewing all community groups')),
              );
            },
            child: const Row(
              children: [
                Icon(
                  Icons.arrow_forward_ios,
                  size: 14,
                  color: Color(0xFF00A884),
                ),
                SizedBox(width: 8),
                Text(
                  'View all groups',
                  style: TextStyle(
                    color: Color(0xFF00A884),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CommunityGroup {
  const _CommunityGroup({
    required this.name,
    required this.lastMessage,
    required this.time,
    this.isAnnouncement = false,
    this.unreadCount = 0,
  });

  final String name;
  final String lastMessage;
  final String time;
  final bool isAnnouncement;
  final int unreadCount;
}
