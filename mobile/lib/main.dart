import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/crash_reporting.dart';
import 'core/push.dart';
import 'state/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Authors of the premium gift models and sounds (CC BY needs credit), shown in Settings → Licenses.
  LicenseRegistry.addLicense(() async* {
    // One credit per line; the license page joins single line breaks, so each line becomes its own paragraph.
    final credits = (await rootBundle.loadString('assets/gift_credits.txt')).replaceAll('\r', '').replaceAll('\n', '\n\n');
    yield LicenseEntryWithLineBreaks(const ['UZARO gifts'], credits);
  });
  await initializeDateFormatting();
  final prefs = await SharedPreferences.getInstance();
  await PushService.instance.initialize();
  await CrashReporting.run(() async => runApp(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: const SadoApp(),
        ),
      ));
}
