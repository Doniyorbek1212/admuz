import 'package:flutter_test/flutter_test.dart';
import 'package:sado/core/file_guard.dart';

void main() {
  const guard = FileGuardSettings();

  test('blocks installers and executables by extension, any case', () {
    expect(guard.checkFile('Sado.apk', 'application/octet-stream'), const FileVerdict('android', 'apk'));
    expect(guard.checkFile('bundle.AAB', ''), const FileVerdict('android', 'aab'));
    expect(guard.checkFile('setup.exe', ''), const FileVerdict('windows', 'exe'));
    expect(guard.checkFile('run.ps1', ''), const FileVerdict('scripts', 'ps1'));
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

  test('catches names disguised with bidi characters', () {
    expect(guard.checkFile('photo\u202Egpj.exe', '')?.kind, 'disguised');
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
