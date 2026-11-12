import 'dart:io';

/// App Store Review Guideline 3.1.1: on iOS, digital goods and services (Telegram Premium and Stars, paid hub
/// ads, paid shop slots) may be sold only through Apple's In-App Purchase, and the app may not point users to
/// other ways of paying. Until those go through IAP, the iOS build hides the purchase flows; everything that is
/// free or already paid keeps working. `--dart-define=STORE_PAYMENTS=on` lifts this for an ad-hoc test build.
///
/// Google Play's payments policy is the same for digital goods (Play Billing only), so the Play build
/// (`--dart-define=STORE=play`) hides them too. The APK from the website keeps card-transfer payments.
bool get storeBlocksExternalPayments =>
    (Platform.isIOS || _store == 'play') && const String.fromEnvironment('STORE_PAYMENTS') != 'on';

const _store = String.fromEnvironment('STORE');
