import 'package:flutter/material.dart';
import 'models/sms_message.dart';

class MessagesPage extends StatefulWidget {
  final List<SmsMessageModel> messages;
  final String initialForwardEmail;
  final ValueChanged<String> onForwardEmailChanged;
  final ValueChanged<SmsMessageModel>? onSimulateMessage;

  const MessagesPage({
    super.key,
    required this.messages,
    required this.initialForwardEmail,
    required this.onForwardEmailChanged,
    this.onSimulateMessage,
  });

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  late String _forwardEmail;

  @override
  void initState() {
    super.initState();
    _forwardEmail = widget.initialForwardEmail;
  }

  void _showEditEmailDialog() async {
    final emailController = TextEditingController(text: _forwardEmail);

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Forward Email'),
        content: TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email Address',
            hintText: 'example@mail.com',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final newEmail = emailController.text.trim();
              if (newEmail.isEmpty || !newEmail.contains('@')) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a valid email address')),
                );
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == true) {
      setState(() {
        _forwardEmail = emailController.text.trim();
      });
      widget.onForwardEmailChanged(_forwardEmail);
    }
}

  void _showSimulateMessageDialog() async {
    final addressController = TextEditingController();
    final bodyController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Simulate Incoming SMS'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: addressController,
              decoration: const InputDecoration(
                labelText: 'Sender Address',
                hintText: '+1234567890',
              ),
            ),
            TextField(
              controller: bodyController,
              decoration: const InputDecoration(
                labelText: 'Message Body',
                hintText: 'Hello from dev!',
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (addressController.text.trim().isEmpty ||
                  bodyController.text.trim().isEmpty) {
                // Simple validation
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter both fields')),
                );
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('Simulate'),
          ),
        ],
      ),
    );

    if (result == true) {
      final simulatedMessage = SmsMessageModel(
        address: addressController.text.trim(),
        body: bodyController.text.trim(),
        date: DateTime.now(),
      );
      if (widget.onSimulateMessage != null) {
        widget.onSimulateMessage!(simulatedMessage);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit Forward Email',
            onPressed: _showEditEmailDialog,
          ),
          IconButton(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Dev Menu: Simulate SMS',
            onPressed: _showSimulateMessageDialog,
          ),
        ],
      ),
      body: widget.messages.isEmpty
          ? const Center(child: Text('No messages received yet.'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: widget.messages.length,
              separatorBuilder: (_, __) => const Divider(),
              itemBuilder: (context, index) {
                final msg = widget.messages[index];
                return ListTile(
                  title: Text(msg.address),
                  subtitle: Text(msg.body),
                  trailing: Text(
                    '${msg.date.hour.toString().padLeft(2, '0')}:${msg.date.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                );
              },
            ),
    );
  }
}