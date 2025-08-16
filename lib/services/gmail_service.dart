import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:http/http.dart' as http;

/// A simple HTTP client that adds Google auth headers to requests.
class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }

  @override
  void close() {
    _client.close();
  }
}

class GmailService {
  final GoogleSignInAccount user;

  GmailService(this.user);

  /// Create an authenticated HTTP client with the user's OAuth tokens
  Future<http.Client> get authenticatedClient async {
    final GoogleSignInAuthentication auth = await user.authentication;
    final authHeaders = {
      'Authorization': 'Bearer ${auth.accessToken}',
    };
    return GoogleAuthClient(authHeaders);
  }

  /// Sends an email using Gmail API
  Future<void> sendEmail({
    required String toEmail,
    required String subject,
    required String body,
  }) async {
    final client = await authenticatedClient;

    try {
      final gmailApi = gmail.GmailApi(client);

      final emailContent = 'To: $toEmail\r\n'
          'Subject: $subject\r\n'
          'Content-Type: text/plain; charset="UTF-8"\r\n'
          '\r\n'
          '$body';

      final base64Email = base64UrlEncode(utf8.encode(emailContent));
      final message = gmail.Message()..raw = base64Email;

      await gmailApi.users.messages.send(message, 'me');
    } finally {
      client.close();
    }
  }
}