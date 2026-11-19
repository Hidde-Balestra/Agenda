import 'package:agenda/dav/http_auth.dart';
import 'package:flutter_test/flutter_test.dart';

String _param(String header, String name) => RegExp('$name="?([^",]*)"?').firstMatch(header)!.group(1)!;

void main() {
  group('parseAuthChallenges', () {
    test('parses a Baïkal Digest challenge', () {
      final c = parseAuthChallenges(
              'Digest realm="BaikalDAV",qop="auth",nonce="6aff140f101ef",opaque="d66d5f05"')
          .single;
      expect(c.scheme, 'digest');
      expect(c.params, {'realm': 'BaikalDAV', 'qop': 'auth', 'nonce': '6aff140f101ef', 'opaque': 'd66d5f05'});
    });

    test('parses multiple joined challenges and quoted commas', () {
      final cs = parseAuthChallenges(
          'Digest realm="a, b", nonce="n", algorithm=SHA-256, qop="auth,auth-int", Basic realm="sabre/dav", charset="UTF-8"');
      expect(cs.map((c) => c.scheme), ['digest', 'basic']);
      expect(cs[0].params['realm'], 'a, b');
      expect(cs[0].params['algorithm'], 'SHA-256');
      expect(cs[0].params['qop'], 'auth,auth-int');
      expect(cs[1].params['charset'], 'UTF-8');
    });

    test('empty header gives no challenges', () {
      expect(parseAuthChallenges(''), isEmpty);
    });
  });

  group('DigestAuth', () {
    test('RFC 2617 §3.5 example (MD5, qop=auth)', () {
      final challenge = AuthChallenge('digest', {
        'realm': 'testrealm@host.com',
        'qop': 'auth,auth-int',
        'nonce': 'dcd98b7102dd2f0e8b11d0f600bfb0c093',
        'opaque': '5ccc069c403ebaf9f0171e9517f40e41',
      });
      final header = DigestAuth('Mufasa', 'Circle Of Life', challenge)
          .authorize('GET', Uri.parse('http://www.nowhere.org/dir/index.html'), cnonce: '0a4f113b');
      expect(header, startsWith('Digest '));
      expect(_param(header, 'response'), '6629fae49393a05397450978507c4ef1');
      expect(_param(header, 'nc'), '00000001');
      expect(_param(header, 'uri'), '/dir/index.html');
      expect(_param(header, 'opaque'), '5ccc069c403ebaf9f0171e9517f40e41');
    });

    test('RFC 7616 §3.9.1 examples (MD5 and SHA-256)', () {
      Map<String, String> params(String alg) => {
            'realm': 'http-auth@example.org',
            'qop': 'auth, auth-int',
            'algorithm': alg,
            'nonce': '7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v',
            'opaque': 'FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS',
          };
      const cnonce = 'f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ';
      final uri = Uri.parse('http://www.example.org/dir/index.html');

      final md5 = DigestAuth('Mufasa', 'Circle of Life', AuthChallenge('digest', params('MD5')))
          .authorize('GET', uri, cnonce: cnonce);
      expect(_param(md5, 'response'), '8ca523f5e9506fed4657c9700eebdbec');

      final sha = DigestAuth('Mufasa', 'Circle of Life', AuthChallenge('digest', params('SHA-256')))
          .authorize('GET', uri, cnonce: cnonce);
      expect(_param(sha, 'response'), '753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1');
    });

    test('nonce count increases per request', () {
      final auth = DigestAuth('u', 'p', AuthChallenge('digest', {'realm': 'r', 'nonce': 'n', 'qop': 'auth'}));
      final uri = Uri.parse('https://h/x');
      expect(_param(auth.authorize('GET', uri), 'nc'), '00000001');
      expect(_param(auth.authorize('GET', uri), 'nc'), '00000002');
    });

    test('supports only answerable challenges', () {
      expect(DigestAuth.supports(AuthChallenge('digest', {'nonce': 'n'})), isTrue);
      expect(DigestAuth.supports(AuthChallenge('digest', {'nonce': 'n', 'qop': 'auth-int'})), isFalse);
      expect(DigestAuth.supports(AuthChallenge('digest', {'nonce': 'n', 'algorithm': 'SHA-512'})), isFalse);
      expect(DigestAuth.supports(AuthChallenge('basic', {'realm': 'r'})), isFalse);
    });
  });
}
