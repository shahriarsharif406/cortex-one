import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cortex_one/api/api_client.dart';
import 'package:cortex_one/api/models.dart';
import 'package:cortex_one/images/image_prep.dart';
import 'package:cortex_one/l10n/strings.dart';
import 'package:cortex_one/state/computer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import 'support/fakes.dart';

Finder key(String k) => find.byKey(Key(k));

/// A gradient picture with EXIF (camera name, orientation) so there is something to strip.
Uint8List jpegWithExif({int w = 300, int h = 200, int orientation = 1}) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, x * 255 ~/ w, y * 255 ~/ h, (x + y) % 256);
    }
  }
  im.exif.imageIfd['Make'] = 'Secret Camera Co';
  im.exif.imageIfd.orientation = orientation;
  im.exif.gpsIfd['GPSLatitudeRef'] = 'N';
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

Uint8List noisePng(int w, int h) {
  final r = Random(1);
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, r.nextInt(256), r.nextInt(256), r.nextInt(256));
    }
  }
  return Uint8List.fromList(img.encodePng(im));
}

Computer comp() => const Computer(
  id: 'a1',
  name: 'Laptop',
  endpoints: ['http://100.64.0.9:8765'],
  token: 'tok',
);

void main() {
  // ----------------------------------------------------------------- prepareImage
  group('prepareImage', () {
    test('the test picture really carries metadata before preparing', () {
      expect(jpegMetadataFree(jpegWithExif()), isFalse);
    });

    test('output is a clean JPEG: no EXIF, no GPS, no camera name', () {
      final out = prepareImage(jpegWithExif());
      expect(out.mediaType, 'image/jpeg');
      expect(jpegMetadataFree(out.bytes), isTrue);
      final text = latin1.decode(out.bytes);
      expect(text.contains('Secret Camera'), isFalse);
      expect(text.contains('Exif'), isFalse);
      expect(text.contains('GPS'), isFalse);
      expect(img.decodeJpg(out.bytes), isNotNull);
    });

    test('large pictures are shrunk to the longest side, small ones are not enlarged', () {
      final big = prepareImage(jpegWithExif(w: 3000, h: 2000));
      expect(max(big.width, big.height), 1280);
      expect(big.width / big.height, closeTo(1.5, 0.02));
      final small = prepareImage(jpegWithExif(w: 300, h: 200));
      expect((small.width, small.height), (300, 200));
    });

    test('data-saver size is smaller', () {
      final out = prepareImage(jpegWithExif(w: 3000, h: 2000), maxSide: 800);
      expect(max(out.width, out.height), 800);
    });

    test('rotation is applied before the EXIF tag is dropped', () {
      final out = prepareImage(jpegWithExif(w: 300, h: 200, orientation: 6));
      expect((out.width, out.height), (200, 300)); // turned upright
    });

    test('a PNG screenshot becomes a clean JPEG', () {
      final out = prepareImage(noisePng(64, 48));
      expect(out.mediaType, 'image/jpeg');
      expect(jpegMetadataFree(out.bytes), isTrue);
    });

    test('garbage is refused with a plain message key', () {
      expect(
        () => prepareImage(Uint8List.fromList(List.filled(100, 7))),
        throwsA(isA<ImagePrepError>().having((e) => e.messageKey, 'key', 'image_failed')),
      );
      expect(() => prepareImage(Uint8List(0)), throwsA(isA<ImagePrepError>()));
    });

    test('a picture that cannot be made small enough is refused, not truncated', () {
      expect(
        () => prepareImage(noisePng(300, 300), limit: 2000),
        throwsA(isA<ImagePrepError>().having((e) => e.messageKey, 'key', 'image_too_big')),
      );
    });

    test('result is within the agent limit', () {
      expect(prepareImage(noisePng(400, 300)).bytes.length, lessThanOrEqualTo(maxUploadBytes));
    });

    test('the metadata check understands comments and other application blocks', () {
      final clean = prepareImage(jpegWithExif()).bytes;
      final withComment = Uint8List.fromList([
        ...clean.sublist(0, 2),
        0xFF, 0xFE, 0x00, 0x05, 0x68, 0x69, 0x21, // COM "hi!"
        ...clean.sublist(2),
      ]);
      expect(jpegMetadataFree(withComment), isFalse);
      expect(jpegMetadataFree(Uint8List.fromList([1, 2, 3, 4, 5])), isFalse);
    });

    test('writes the sample the Python side validates (only when asked)', () {
      if (Platform.environment['CW_WRITE_SAMPLE'] != '1') return;
      final out = prepareImage(jpegWithExif(w: 640, h: 480, orientation: 6));
      File('test/fixtures/prepared_sample.jpg')
        ..createSync(recursive: true)
        ..writeAsBytesSync(out.bytes);
    });
  });

  // -------------------------------------------------------------------- the API body
  test('startTask sends the pictures as base64 with their type, and nothing else new', () async {
    Map<String, dynamic>? body;
    final client = MockClient((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'id': 'job9'}), 202);
    });
    final api = HttpCortexApi('http://100.64.0.9:8765', 'tok', client: client);
    final pic = prepareImage(jpegWithExif());
    expect(await api.startTask('look', images: [pic]), 'job9');
    expect(body!['instruction'], 'look');
    expect(body!['wait'], false);
    final imgs = body!['images'] as List;
    expect(imgs.single['media_type'], 'image/jpeg');
    expect(base64Decode(imgs.single['data'] as String), pic.bytes);
    // without pictures the body is exactly as before
    await api.startTask('plain');
    expect(body!.containsKey('images'), isFalse);
  });

  test('a refused picture shows the agent\'s reason, a 413 is an invalid-request error', () {
    const s = S('en');
    expect(
      s.error(const ApiException(ApiErrorKind.invalid, detail: 'The JPEG contains metadata (EXIF/XMP).')),
      contains('metadata'),
    );
  });

  test('400 / 411 / 413 map to "invalid", never to a vague server error', () async {
    for (final code in [400, 411, 413]) {
      final client = MockClient((_) async => http.Response(jsonEncode({'detail': 'nope'}), code));
      final api = HttpCortexApi('http://100.64.0.9:8765', 'tok', client: client);
      await expectLater(
        api.startTask('x'),
        throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.invalid)),
      );
    }
  });

  // -------------------------------------------------------------------- the UI
  group('attaching pictures', () {
    Future<Harness> home(WidgetTester tester, {FakePictures? pictures}) async {
      final h = Harness(pictures: pictures, computers: [comp()]);
      await h.pump(tester);
      await flush(tester);
      return h;
    }

    testWidgets('a gallery picture shows up with a remove button and is counted', (tester) async {
      final h = await home(tester, pictures: FakePictures(gallery: jpegWithExif()));
      await tester.ensureVisible(key('attach_gallery'));
      await tester.tap(key('attach_gallery'));
      await flush(tester);
      expect(key('picture_0'), findsOneWidget);
      expect(find.text('Pictures: 1/3'), findsNothing); // bn by default
      expect(find.text('ছবি: 1/৩'), findsOneWidget);
      await tester.tap(key('picture_remove_0'));
      await flush(tester);
      expect(key('picture_0'), findsNothing);
      expect(h.pictures.asked, ['gallery']);
    });

    testWidgets('the camera works and cancelling attaches nothing', (tester) async {
      final h = await home(tester, pictures: FakePictures(camera: null));
      await tester.ensureVisible(key('attach_camera'));
      await tester.tap(key('attach_camera'));
      await flush(tester);
      expect(key('picture_0'), findsNothing);
      h.pictures.camera = jpegWithExif();
      await tester.tap(key('attach_camera'));
      await flush(tester);
      expect(key('picture_0'), findsOneWidget);
    });

    testWidgets('no more than three, then the buttons are disabled', (tester) async {
      final h = await home(tester, pictures: FakePictures(gallery: jpegWithExif()));
      for (var i = 0; i < 3; i++) {
        await tester.ensureVisible(key('attach_gallery'));
        await tester.tap(key('attach_gallery'));
        await flush(tester);
      }
      expect(key('picture_2'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(key('attach_gallery')).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(key('attach_camera')).onPressed, isNull);
      expect(h.pictures.asked.length, 3);
    });

    testWidgets('a broken file gives a plain message and is not attached', (tester) async {
      await home(tester, pictures: FakePictures(gallery: Uint8List.fromList(List.filled(50, 3))));
      await tester.ensureVisible(key('attach_gallery'));
      await tester.tap(key('attach_gallery'));
      await flush(tester);
      expect(key('picture_error'), findsOneWidget);
      expect(key('picture_0'), findsNothing);
    });

    testWidgets('sending uploads cleaned pictures only, then clears them', (tester) async {
      final h = await home(tester, pictures: FakePictures(gallery: jpegWithExif(w: 2400, h: 1600)));
      await tester.ensureVisible(key('attach_gallery'));
      await tester.tap(key('attach_gallery'));
      await flush(tester);
      await tester.enterText(key('command_field'), 'what is wrong here?');
      h.api.taskPolls = [
        const TaskStatus(
          id: 'job1',
          status: 'ok',
          reply: 'A dialog box.',
          steps: [],
          pending: [],
          stoppedReason: '',
        ),
      ];
      await tester.ensureVisible(key('send_button'));
      await tester.tap(key('send_button'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(h.api.sentImages.single.length, 1);
      final sent = h.api.sentImages.single.single;
      expect(jpegMetadataFree(sent.bytes), isTrue);
      expect(max(sent.width, sent.height), lessThanOrEqualTo(1280));
      expect(latin1.decode(sent.bytes).contains('Secret Camera'), isFalse);
      expect(key('picture_0'), findsNothing); // cleared after a successful send
    });

    testWidgets('data-saver makes the pictures smaller', (tester) async {
      final h = await home(tester, pictures: FakePictures(gallery: jpegWithExif(w: 2400, h: 1600)));
      await h.state.setDataSaverMode('on');
      await tester.pump();
      await tester.ensureVisible(key('attach_gallery'));
      await tester.tap(key('attach_gallery'));
      await flush(tester);
      await tester.enterText(key('command_field'), 'x');
      h.api.taskPolls = [
        const TaskStatus(id: 'j', status: 'ok', reply: 'ok', steps: [], pending: [], stoppedReason: ''),
      ];
      await tester.ensureVisible(key('send_button'));
      await tester.tap(key('send_button'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final sent = h.api.sentImages.single.single;
      expect(max(sent.width, sent.height), 800);
    });

    testWidgets('a refusal from the agent is shown with its reason and the pictures stay', (tester) async {
      final api = FakeApi();
      final h = await home(tester, pictures: FakePictures(gallery: jpegWithExif()));
      expect(api, isNotNull);
      await tester.ensureVisible(key('attach_gallery'));
      await tester.tap(key('attach_gallery'));
      await flush(tester);
      await tester.enterText(key('command_field'), 'x');
      h.api.startError = const ApiException(ApiErrorKind.invalid, detail: 'The JPEG contains metadata');
      await tester.ensureVisible(key('send_button'));
      await tester.tap(key('send_button'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(key('task_error'), findsOneWidget);
      expect(key('picture_0'), findsOneWidget); // kept so the owner can retry
    });

    testWidgets('the note says pictures are cleaned and text inside them is not obeyed', (tester) async {
      await home(tester);
      await tester.ensureVisible(key('attach_gallery'));
      expect(find.textContaining('EXIF'), findsWidgets);
    });
  });
}
