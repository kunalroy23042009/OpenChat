import 'package:flutter/material.dart';

import 'conversation_repository.dart';

class TaskBoardPage extends StatefulWidget {
  const TaskBoardPage({
    super.key,
    required this.repository,
    required this.conversationId,
  });

  final ConversationRepository repository;
  final String conversationId;

  @override
  State<TaskBoardPage> createState() => _TaskBoardPageState();
}

class _TaskBoardPageState extends State<TaskBoardPage> {
  static const columns = <String, String>{
    'todo': 'To-do',
    'in_progress': 'In progress',
    'review': 'Review',
    'completed': 'Completed',
  };

  @override
  void initState() {
    super.initState();
    widget.repository.addListener(_changed);
    widget.repository.loadTasks(widget.conversationId);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.repository.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Team task board')),
    body: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      children: columns.entries.map((column) {
        final tasks = widget.repository
            .tasksFor(widget.conversationId)
            .where((task) => task.status == column.key)
            .toList();
        return SizedBox(
          width: 290,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${column.value}  ${tasks.length}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Divider(),
                  Expanded(
                    child: tasks.isEmpty
                        ? const Center(child: Text('No tasks'))
                        : ListView(
                            children: tasks
                                .map(
                                  (task) => Card(
                                    child: ListTile(
                                      title: Text(task.title),
                                      subtitle: Text(
                                        task.priority.toUpperCase(),
                                      ),
                                      trailing: PopupMenuButton<String>(
                                        tooltip: 'Move task',
                                        onSelected: (status) =>
                                            widget.repository.updateTaskStatus(
                                              widget.conversationId,
                                              task.id,
                                              status,
                                            ),
                                        itemBuilder: (_) => columns.entries
                                            .map(
                                              (entry) => PopupMenuItem(
                                                value: entry.key,
                                                child: Text(entry.value),
                                              ),
                                            )
                                            .toList(),
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    ),
  );
}

class ResourceVaultPage extends StatelessWidget {
  const ResourceVaultPage({super.key, required this.messages});

  final List<GroupMessage> messages;

  @override
  Widget build(BuildContext context) {
    final categories = <String, bool Function(GroupMessage)>{
      'Documents': (message) => message.type == 'document',
      'Links': (message) => RegExp(r'https?://').hasMatch(message.content),
      'Code': (message) =>
          message.type == 'code_snippet' || message.content.contains('```'),
      'Media': (message) =>
          const {'image', 'video', 'audio'}.contains(message.type),
    };

    return DefaultTabController(
      length: categories.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Resource vault'),
          bottom: TabBar(
            isScrollable: true,
            tabs: categories.keys.map((name) => Tab(text: name)).toList(),
          ),
        ),
        body: TabBarView(
          children: categories.values.map((filter) {
            final items = messages.where(filter).toList();
            if (items.isEmpty) {
              return const Center(child: Text('Nothing shared here yet'));
            }
            return ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, index) => ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(
                  items[index].content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(items[index].senderName ?? 'Shared resource'),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
