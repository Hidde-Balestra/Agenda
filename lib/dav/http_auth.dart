import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A parsed `WWW-Authenticate` challenge.
class AuthChallenge {
  AuthChallenge(this.scheme, this.params);
  final String scheme; // lower-case, e.g. 'digest' or 'basic'
  final Map<String, String> params; // lower-case keys

  @override
  String toString() => 'AuthChallenge($scheme, $params)';
}

/// Parses one or more challenges from a `WWW-Authenticate` header value.
///
/// Multiple headers are joined by `package:http` with ", ", so the value may
/// contain e.g. `Digest realm="x", nonce="y", Basic realm="x"`.
List<AuthChallenge> parseAuthChallenges(String header) {
  final challenges = <AuthChallenge>[];
  var i = 0;
  AuthChallenge? current;

  void skipSeparators() {
    while (i < header.length && (header[i] == ' ' || header[i] == ',' || header[i] == '\t')) {
      i++;
    }
  }

  String readToken() {
    final start = i;
    while (i < header.length && !' \t,="'.contains(header[i])) {
      i++;
    }
    return header.substring(start, i);
  }

  while (true) {
    skipSeparators();
    if (i >= header.length) break;
    final token = readToken();
    if (token.isEmpty) {
      i++;
      continue;
    }
    // Look ahead: `token=` is a parameter, otherwise a new scheme.
    var j = i;
    while (j < header.length && header[j] == ' ') {
      j++;
    }
    if (j < header.length && header[j] == '=' && current != null) {
      i = j + 1;
      while (i < header.length && header[i] == ' ') {
        i++;
      }
      String value;
      if (i < header.length && header[i] == '"') {
        i++;
        final buffer = StringBuffer();
        while (i < header.length && header[i] != '"') {
          if (header[i] == '\\' && i + 1 < header.length) i++;
          buffer.write(header[i]);
          i++;
        }
        i++; // closing quote
        value = buffer.toString();
      } else {
        value = readToken();
      }
      current.params[token.toLowerCase()] = value;
    } else {
      current = AuthChallenge(token.toLowerCase(), {});
      challenges.add(current);
    }
  }
  return challenges;
}

/// HTTP Digest authentication (RFC 7616 / RFC 2617), as used by Baïkal/sabre/dav.
class DigestAuth {
  DigestAuth(this.username, this.password, this.challenge, {Random? random}) : _random = random ?? Random.secure();

  final String username;
  final String password;
  final AuthChallenge challenge;
  final Random _random;
  int _nonceCount = 0;

  String get realm => challenge.params['realm'] ?? '';
  String get nonce => challenge.params['nonce'] ?? '';
  String get algorithm => (challenge.params['algorithm'] ?? 'MD5').toUpperCase();

  /// Whether this implementation can answer the challenge.
  static bool supports(AuthChallenge c) {
    if (c.scheme != 'digest' || c.params['nonce'] == null) return false;
    final alg = (c.params['algorithm'] ?? 'MD5').toUpperCase();
    final qop = c.params['qop'];
    final qopOk = qop == null || qop.split(',').map((q) => q.trim().toLowerCase()).contains('auth');
    return qopOk && const {'MD5', 'MD5-SESS', 'SHA-256', 'SHA-256-SESS'}.contains(alg);
  }

  String _hash(String input) {
    final bytes = utf8.encode(input);
    return (algorithm.startsWith('SHA-256') ? sha256.convert(bytes) : md5.convert(bytes)).toString();
  }

  String _cnonce() => List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  /// Builds the `Authorization` header value for a request.
  String authorize(String method, Uri uri, {String? cnonce}) {
    final digestUri = uri.hasQuery ? '${uri.path}?${uri.query}' : (uri.path.isEmpty ? '/' : uri.path);
    final qops = challenge.params['qop']?.split(',').map((q) => q.trim().toLowerCase()).toList();
    final useQop = qops != null && qops.contains('auth');
    final cn = cnonce ?? _cnonce();
    final nc = (++_nonceCount).toRadixString(16).padLeft(8, '0');

    var ha1 = _hash('$username:$realm:$password');
    if (algorithm.endsWith('-SESS')) ha1 = _hash('$ha1:$nonce:$cn');
    final ha2 = _hash('$method:$digestUri');
    final response = useQop ? _hash('$ha1:$nonce:$nc:$cn:auth:$ha2') : _hash('$ha1:$nonce:$ha2');

    String q(String v) => '"${v.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    final parts = <String>[
      'username=${q(username)}',
      'realm=${q(realm)}',
      'nonce=${q(nonce)}',
      'uri=${q(digestUri)}',
      'algorithm=${challenge.params['algorithm'] ?? 'MD5'}',
      'response=${q(response)}',
      if (challenge.params['opaque'] != null) 'opaque=${q(challenge.params['opaque']!)}',
      if (useQop) ...['qop=auth', 'nc=$nc', 'cnonce=${q(cn)}'],
    ];
    return 'Digest ${parts.join(', ')}';
  }
}
