import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:another_telephony/telephony.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'login_page.dart';
import 'messages_page.dart';
import 'models/sms_message.dart';
import 'services/gmail_service.dart';
import 'services/db_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize port and configure the Foreground Service at app start.
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions:  AndroidNotificationOptions(
      channelId: 'sms_forwarder_fg',
      channelName: 'SMS Forwarder Service',
      channelDescription: 'Keeps SMS listening and forwarding active.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions:  ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(15000), // harmless heartbeat
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  runApp(const SmsForwarderApp());
}

/// Top-level callback required by flutter_foreground_task.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(SmsKeepAliveTask());
}

/// Lightweight keep-alive task; we don't do any heavy work here.
class SmsKeepAliveTask extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    FlutterForegroundTask.updateService(
      notificationTitle: 'SMS Forwarder is active',
      notificationText: 'Listening for incoming SMS…',
    );
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Optional heartbeat - keep notification fresh.
    FlutterForegroundTask.updateService(
      notificationText: 'Listening… ${timestamp.toLocal()}',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Background handler for SMS. Must be top-level and annotated as entry-point.
@pragma('vm:entry-point')
void onBackgroundSms(SmsMessage message) {
  // ignore: avoid_print
  print('[BG] SMS from ${message.address} len=${message.body?.length ?? 0}');
}

class SmsForwarderApp extends StatefulWidget {
  const SmsForwarderApp({super.key});
  @override
  State<SmsForwarderApp> createState() => _SmsForwarderAppState();
}

class _SmsForwarderAppState extends State<SmsForwarderApp> {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'https://www.googleapis.com/auth/gmail.send'],
  );

  final Telephony _telephony = Telephony.instance;

  GoogleSignInAccount? _user;
  static const String _kForwardEmailKey = 'forward_email';

  String _forwardEmail = '';
  final List<SmsMessageModel> _messages = [];
  final DbService _dbService = DbService();

  @override
  void initState() {
    super.initState();
    _loadForwardEmail();

    // Receive data from TaskHandler if you ever send it (optional).
    FlutterForegroundTask.addTaskDataCallback((data) {
      debugPrint('[FGS->UI] $data');
    });

    _googleSignIn.onCurrentUserChanged.listen((account) async {
      final wasNull = _user == null;
      setState(() => _user = account);
      if (_user != null && wasNull) {
        await _postLoginInit();
      }
    });

    _googleSignIn.signInSilently();
  }

  // ---------- Foreground Service helpers ----------
  Future<void> _requestFgPermissions() async {
    final notifPerm = await FlutterForegroundTask.checkNotificationPermission();
    if (notifPerm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        // Requires android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  Future<void> _ensureFgServiceStarted() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'SMS Forwarder is active',
        notificationText: 'Running in background',
      );
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: 100, // any int
      // Use a messaging-friendly service type; you may also set this in manifest.
      serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
      notificationTitle: 'SMS Forwarder is active',
      notificationText: 'Listening for incoming SMS…',
      notificationButtons: const [],
      callback: startCallback,
    );
  }

  // ---------- Post-login initialization ----------
  Future<void> _postLoginInit() async {
    // Request both Android permission_handler SMS + plugin’s combo request
    final bool? pluginGranted = await _telephony.requestPhoneAndSmsPermissions;
    final permStatus = await Permission.sms.status;
    if (pluginGranted != true || !permStatus.isGranted) {
      if (!permStatus.isGranted) await Permission.sms.request();
      // If still not granted, bail gracefully.
      final nowGranted = await Permission.sms.status;
      if (pluginGranted != true || !nowGranted.isGranted) {
        debugPrint('[APP] SMS permission not granted; listener not started.');
        return;
      }
    }

    await _loadMessagesFromDb();

    // Start listening to *real* SMS (RCS/chat won’t trigger this)
    _telephony.listenIncomingSms(
      onNewMessage: (message) async {
        debugPrint('[FG] SMS from ${message.address}: ${message.body}');
        if (message.address == null || message.body == null) return;

        final sms = SmsMessageModel(
          address: message.address!,
          body: message.body!,
          date: DateTime.now(),
        );

        // Persist and update UI
        await _dbService.insertMessage(sms);
        if (mounted) {
          setState(() => _messages.insert(0, sms));
        }

        // Optional forwarding via Gmail
        if (_user != null && _forwardEmail.isNotEmpty) {
          try {
            final gmailService = GmailService(_user!);
            await gmailService.sendEmail(
              toEmail: _forwardEmail,
              subject: 'SMS from ${sms.address}',
              body: sms.body,
            );
            debugPrint('[APP] Email forwarded.');
          } catch (e) {
            debugPrint('[APP] Forward failed: $e');
          }
        }
      },
      // This runs when the app is backgrounded; keep it very light
      onBackgroundMessage: onBackgroundSms,
    );

    // Foreground Service: request needed perms and start it.
    await _requestFgPermissions();
    await _ensureFgServiceStarted();
  }

  // ---------- Persistence ----------
  Future<void> _loadForwardEmail() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _forwardEmail = prefs.getString(_kForwardEmailKey) ?? '';
    });
  }

  Future<void> _saveForwardEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kForwardEmailKey, email);
  }

  Future<void> _loadMessagesFromDb() async {
    final messagesFromDb = await _dbService.getMessages();
    debugPrint('[APP] Loading Messages');
    setState(() {
      _messages
        ..clear()
        ..addAll(messagesFromDb);
    });
  }

  // ---------- Auth ----------
  void _handleSignIn() async {
    try {
      await _googleSignIn.signIn();
    } catch (e) {
      debugPrint('Sign-in error: $e');
    }
  }

  Future<void> _signOut() async {
    try {
      await _googleSignIn.disconnect();
      setState(() => _user = null);
    } catch (e) {
      debugPrint('Sign-out error: $e');
    }
  }

  @override
  void dispose() {
    // Do NOT stop the foreground service; we want it to keep running.
    _dbService.close();
    FlutterForegroundTask.removeTaskDataCallback((_) {});
    super.dispose();
  }

  // ---------- UI ----------
  String _initialsFromName(String? name, String? email) {
    final src = (name != null && name.trim().isNotEmpty) ? name.trim() : (email ?? '').trim();
    if (src.isEmpty) return '?';
    final parts = src.split(RegExp(r'\s+'));
    final a = parts.first.isNotEmpty ? parts.first[0] : '';
    final b = parts.length > 1 && parts.last.isNotEmpty ? parts.last[0] : '';
    final initials = (a + b).toUpperCase();
    return initials.isEmpty ? '?' : initials;
  }

  Future<void> _showSimulateMessageDialog() async {
    final fromCtrl = TextEditingController(text: '123-456-7890');
    final bodyCtrl = TextEditingController(text: 'Test message');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Simulate SMS'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: fromCtrl, decoration: const InputDecoration(labelText: 'From (address/number)')),
            const SizedBox(height: 12),
            TextField(controller: bodyCtrl, decoration: const InputDecoration(labelText: 'Body'), maxLines: 3),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );

    if (ok == true) {
      final msg = SmsMessageModel(
        address: fromCtrl.text.trim().isEmpty ? 'Unknown' : fromCtrl.text.trim(),
        body: bodyCtrl.text,
        date: DateTime.now(),
      );

      setState(() => _messages.insert(0, msg));

      if (_user != null && _forwardEmail.isNotEmpty) {
        try {
          final gmailService = GmailService(_user!);
          await gmailService.sendEmail(
            toEmail: _forwardEmail,
            subject: 'Simulated SMS from ${msg.address}',
            body: msg.body,
          );
          debugPrint('Email sent for simulated message.');
        } catch (e) {
          debugPrint('Failed to send email for simulated message: $e');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SMS Forwarder',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: WithForegroundTask(
        child: Scaffold(
          appBar: AppBar(title: const Text('SMS Forwarder'), centerTitle: true),
          drawer: Drawer(
            child: SafeArea(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  if (_user != null)
                    UserAccountsDrawerHeader(
                      accountName: Text(_user?.displayName ?? 'Signed-in user'),
                      accountEmail: Text(_user?.email ?? ''),
                      currentAccountPicture: CircleAvatar(
                        child: Text(_initialsFromName(_user?.displayName, _user?.email)),
                      ),
                    )
                  else
                    const DrawerHeader(child: Text('Not signed in')),

                  // Read-only forward email display
                  ListTile(
                    leading: const Icon(Icons.alternate_email_outlined),
                    title: const Text('Forwarding to'),
                    subtitle: Text(_forwardEmail.isEmpty ? 'Not set' : _forwardEmail),
                    enabled: false,
                  ),

                  ListTile(
                    leading: const Icon(Icons.sms_outlined),
                    title: const Text('Simulate message'),
                    onTap: () async {
                      Navigator.pop(context);
                      await _showSimulateMessageDialog();
                    },
                  ),

                  const Divider(),

                  if (_user != null)
                    ListTile(
                      leading: const Icon(Icons.logout),
                      title: const Text('Sign out'),
                      onTap: () async {
                        Navigator.pop(context);
                        await _signOut();
                      },
                    )
                  else
                    ListTile(
                      leading: const Icon(Icons.login),
                      title: const Text('Sign in'),
                      onTap: () {
                        Navigator.pop(context);
                        _handleSignIn();
                      },
                    ),
                ],
              ),
            ),
          ),
          body: _user == null
              ? LoginPage(
                  initialEmail: _forwardEmail,
                  onEmailChanged: (email) async {
                    setState(() => _forwardEmail = email);
                    await _saveForwardEmail(email);
                  },
                  onSignInPressed: _handleSignIn,
                )
              : MessagesPage(
                  messages: _messages,
                  initialForwardEmail: _forwardEmail,
                  onForwardEmailChanged: (newEmail) async {
                    setState(() => _forwardEmail = newEmail);
                    await _saveForwardEmail(newEmail);
                  },
                  onSimulateMessage: (SmsMessageModel msg) async {
                    setState(() => _messages.insert(0, msg));
                    if (_user != null && _forwardEmail.isNotEmpty) {
                      try {
                        final gmailService = GmailService(_user!);
                        await gmailService.sendEmail(
                          toEmail: _forwardEmail,
                          subject: 'Simulated SMS from ${msg.address}',
                          body: msg.body,
                        );
                      } catch (e) {
                        debugPrint('Failed to send email for simulated message: $e');
                      }
                    }
                  },
                ),
        ),
      ),
    );
  }
}