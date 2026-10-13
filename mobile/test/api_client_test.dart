import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/l10n/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

HttpCortexApi api(
  Future<http.Response> Function(http.Request) handler, {
  String? token = 'T0K',
}) => HttpCortexApi(
  'http://100.64.0.1:8765',
  token,
  client: MockClient(handler),
  timeout: const Duration(milliseconds: 200),
);

http.Response json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('normalizeServerAddress', () {
    test('adds scheme and the default port', () {
      expect(normalizeServerAddress('100.64.1.2'), 'http://100.64.1.2:8765');
      expect(
        normalizeServerAddress(' 100.64.1.2:9000 '),
        'http://100.64.1.2:9000',
      );
      expect(
        normalizeServerAddress('http://laptop.tail1234.ts.net'),
        'http://laptop.tail1234.ts.net:8765',
      );
      expect(
        normalizeServerAddress('https://x.example:8443/'),
        'https://x.example:8443',
      );
    });
    test('rejects junk', () {
      for (final bad in [
        '',
        '   ',
        'a b',
        'ftp://host',
        'http://u:p@host',
        'http://host/path',
        'http://',
      ]) {
        expect(normalizeServerAddress(bad), isNull, reason: bad);
      }
    });
  });

  group('requests', () {
    test('send the bearer token and JSON; pairing sends none', () async {
      late http.Request seen;
      final c = api((r) async {
        seen = r;
        return json({'status': 'ok', 'message': 'ok', 'data': {}});
      });
      await c.runAction('lock');
      expect(seen.headers['Authorization'], 'Bearer T0K');
      expect(seen.url.toString(), 'http://100.64.0.1:8765/actions/lock');
      expect(jsonDecode(seen.body), {'params': {}});

      final p = api((r) async {
        seen = r;
        return json({'token': 'new-token'});
      }, token: null);
      expect(await p.pair('123456', 'phone'), 'new-token');
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(seen.body), {'code': '123456', 'device_name': 'phone'});
    });

    test(
      'startTask asks the agent to run asynchronously and returns the job id',
      () async {
        late Map body;
        final c = api((r) async {
          body = jsonDecode(r.body) as Map;
          return json({'id': 'abc', 'status': 'running'}, 202);
        });
        expect(await c.startTask('ফাইল দেখাও'), 'abc');
        expect(body, {'instruction': 'ফাইল দেখাও', 'wait': false});
      },
    );

    test(
      'parses tasks, pending confirmations and audit rows (Bangla text intact)',
      () async {
        final c = api((r) async {
          if (r.url.path == '/ai/tasks/abc') {
            return json({
              'id': 'abc',
              'status': 'ok',
              'reply': '২টি আইটেম আছে।',
              'steps': [
                {
                  'tool': 'list_files',
                  'input': {'path': 'C:\\x'},
                  'ok': true,
                  'message': '2 item(s).',
                },
              ],
              'pending_confirmations': [
                {
                  'action': 'shutdown',
                  'params': {},
                  'confirm_token': 'tk',
                  'expires_in': 60,
                },
              ],
              'stopped_reason': '',
            });
          }
          if (r.url.path == '/ai/pending') {
            return json([
              {
                'confirm_token': 'tk2',
                'action': 'run_script',
                'params': {'name': 'backup'},
                'expires_in': 33,
                'summary': "Run the approved script 'backup'",
                'command': ['powershell', '-File', 'b.ps1'],
              },
            ]);
          }
          return json([
            {
              'ts': 1760000000.5,
              'actor': 'device:phone',
              'via': 'http',
              'action': 'lock',
              'status': 'ok',
              'detail': 'Locked.',
            },
          ]);
        });
        final t = await c.getTask('abc');
        expect(t.reply, '২টি আইটেম আছে।');
        expect(t.steps.single.tool, 'list_files');
        expect(t.pending.single.confirmToken, 'tk');
        expect(t.running, isFalse);
        final p = (await c.pending()).single;
        expect(p.command, ['powershell', '-File', 'b.ps1']);
        expect(p.expiresIn, 33);
        expect((await c.audit()).single.action, 'lock');
      },
    );

    test('confirm and cancel send only the token', () async {
      final bodies = <String, Map>{};
      final c = api((r) async {
        bodies[r.url.path] = jsonDecode(r.body) as Map;
        return json({
          'status': 'ok',
          'message': 'done',
          'action': 'shutdown',
          'data': {},
        });
      });
      await c.confirm('tkn');
      await c.cancel('tkn');
      expect(bodies['/ai/confirm'], {'confirm_token': 'tkn'});
      expect(bodies['/ai/cancel'], {'confirm_token': 'tkn'});
    });
  });

  group('errors', () {
    Future<ApiException> failing(
      Future<http.Response> Function(http.Request) h,
    ) async {
      try {
        await api(h).runAction('status');
      } on ApiException catch (e) {
        return e;
      }
      throw StateError('did not throw');
    }

    test('status codes map to kinds', () async {
      final cases = {
        401: ApiErrorKind.unauthorized,
        403: ApiErrorKind.forbidden,
        404: ApiErrorKind.notFound,
        422: ApiErrorKind.invalid,
        429: ApiErrorKind.rateLimited,
        503: ApiErrorKind.unavailable,
        500: ApiErrorKind.server,
      };
      for (final entry in cases.entries) {
        final e = await failing((r) async => json({'detail': 'x'}, entry.key));
        expect(e.kind, entry.value, reason: '${entry.key}');
      }
    });

    test(
      '503 keeps the agent message (e.g. missing API key) but never a stack trace',
      () async {
        final e = await failing(
          (r) async => json({
            'detail': 'AI is not set up: ANTHROPIC_API_KEY is empty.',
          }, 503),
        );
        expect(e.detail, contains('ANTHROPIC_API_KEY'));
        final text = const S('bn').error(e);
        expect(text, contains('এই মুহূর্তে কাজটি করা যাচ্ছে না'));
        expect(text, contains('ANTHROPIC_API_KEY'));
      },
    );

    test('FastAPI validation errors (detail is a list) do not crash', () async {
      final e = await failing(
        (r) async => json({
          'detail': [
            {'msg': 'bad'},
          ],
        }, 422),
      );
      expect(e.kind, ApiErrorKind.invalid);
      expect(e.detail, '');
    });

    test('network failures become the network kind', () async {
      expect(
        (await failing(
          (r) async => throw const SocketException('no route'),
        )).kind,
        ApiErrorKind.network,
      );
      expect(
        (await failing((r) async => throw http.ClientException('x'))).kind,
        ApiErrorKind.network,
      );
    });

    test('a hanging laptop times out', () async {
      final e = await failing((r) => Completer<http.Response>().future);
      expect(e.kind, ApiErrorKind.timeout);
    });

    test('garbage responses are reported, not crashed on', () async {
      expect(
        (await failing((r) async => http.Response('<html>', 200))).kind,
        ApiErrorKind.badResponse,
      );
      expect(
        (await failing((r) async => json([1, 2, 3]))).kind,
        ApiErrorKind.badResponse,
      );
    });

    test('every error kind has Bangla and English text', () {
      for (final kind in ApiErrorKind.values) {
        for (final lang in ['bn', 'en']) {
          final text = S(lang).error(ApiException(kind));
          expect(text, isNotEmpty);
          expect(
            text.startsWith('err_'),
            isFalse,
            reason: '$kind $lang is missing a string',
          );
        }
      }
    });
  });

  test('Bangla and English have exactly the same keys', () {
    expect(S.bnKeys, S.enKeys);
    for (final key in S.keys) {
      expect(const S('bn').t(key).trim(), isNotEmpty, reason: key);
      expect(const S('en').t(key).trim(), isNotEmpty, reason: key);
    }
  });
}
