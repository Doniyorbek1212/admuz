import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/file_guard.dart';

void main() {
  const guard = FileGuardSettings();

  test('blocks installers and executables by extension, any case', () {
    expect(guard.checkFile('Sado.apk', 'application/octet-stream'), const FileVerdict('android', 'apk'));
    expect(guard.checkFile('bundle.AAB', ''), const FileVerdict('android', 'aab'));
    expect(guard.checkFile('setup.exe', ''), const FileVerdict('windows', 'exe'));
    expect(guard.checkFile('run.ps1', ''), const FileVerdict('windows', 'ps1'));
    expect(guard.checkFile('report.xlsm', ''), const FileVerdict('macros', 'xlsm'));
  });

  test('lets ordinary files through', () {
    expect(guard.checkFile('photo.jpg', 'image/jpeg'), isNull);
    expect(guard.checkFile('contract.pdf', 'application/pdf'), isNull);
    expect(guard.checkFile('notes', ''), isNull);
    // Archives are opt-in.
    expect(guard.checkFile('photos.zip', 'application/zip'), isNull);
  });

  test('sees through double extensions, trailing dots and spaces', () {
    expect(guard.checkFile('invoice.pdf.exe', ''), const FileVerdict('windows', 'exe'));
    expect(guard.checkFile('game.apk. ', ''), const FileVerdict('android', 'apk'));
  });

  test('catches names disguised with bidi characters or zero-width marks', () {
    expect(guard.checkFile('photo\u202Egpj.exe', '')?.kind, 'disguised');
    expect(guard.checkFile('set\u200Bup.ex\u200Be', ''), const FileVerdict('windows', 'exe'));
  });

  test('does not block safe files with emoji, Arabic-script marks or source code', () {
    expect(guard.checkFile('oila \u{1F468}\u200D\u{1F469}\u200D\u{1F467}.jpg', 'image/jpeg'), isNull);
    expect(guard.checkFile('\u0633\u0646\u062F\u200F.pdf', 'application/pdf'), isNull);
    expect(guard.checkFile('\u202Bhujjat\u202C.docx', ''), isNull);
    expect(guard.checkFile('main.py', 'text/x-python'), isNull);
    expect(guard.checkFile('firmware.bin', ''), isNull);
  });

  test('only programs are deleted automatically', () {
    expect(guard.checkFile('Payme.apk', '')!.deletable, isTrue);
    expect(guard.checkFile('photo\u202Egpj.exe', '')!.deletable, isTrue);
    expect(guard.checkFile('report.xlsm', '')!.deletable, isFalse);
    expect(guard.copyWith(customExtensions: {'torrent'}).checkFile('a.torrent', '')!.deletable, isFalse);
  });

  test('recognises programs by their content whatever they are called', () {
    final apk = [0x50, 0x4B, 0x03, 0x04, ...List.filled(26, 0), ...'AndroidManifest.xml'.codeUnits];
    expect(sniffProgram(apk), 'android');
    expect(sniffProgram([0x4D, 0x5A, 0x90, 0x00]), 'windows');
    expect(sniffProgram([0x7F, 0x45, 0x4C, 0x46, 2]), 'linux');
    expect(sniffProgram([0x50, 0x4B, 0x03, 0x04, ...'word/document.xml'.codeUnits]), isNull);
    expect(sniffProgram([0xFF, 0xD8, 0xFF, 0xE0]), isNull);
  });

  test('uses the MIME type when the name hides the program', () {
    expect(guard.checkFile('video.mp4', 'application/vnd.android.package-archive'), const FileVerdict('android', 'mp4'));
  });

  test('honours chosen categories, custom extensions and the switch', () {
    final archivesOnly = guard.copyWith(categories: {'archives'}, customExtensions: {'torrent'});
    expect(archivesOnly.checkFile('Sado.apk', ''), isNull);
    expect(archivesOnly.checkFile('photos.zip', ''), const FileVerdict('archives', 'zip'));
    expect(archivesOnly.checkFile('film.torrent', ''), const FileVerdict('custom', 'torrent'));
    expect(guard.copyWith(enabled: false).checkFile('setup.exe', ''), isNull);
  });
}
