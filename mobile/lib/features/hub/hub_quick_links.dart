import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/market_models.dart' show resolveMediaUrl;
import '../../core/api/sado_api.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../widgets/common.dart';

/// Links a user may pin to the hub's quick row (admin-pinned ones come on top and do not count).
const maxQuickLinks = 3;

/// How long the hub keeps the admin-pinned links after leaving it.
const _adminLinksCacheFor = Duration(minutes: 10);

/// A service pinned to the hub: a web link, or the service's app when it is installed.
class QuickLink {
  const QuickLink(this.name, this.url, {this.logo, this.androidPackage, this.fromAdmin = false});

  /// A paid link from the admin panel (`GET /v1/quick-links`).
  factory QuickLink.fromAdmin(Map<String, dynamic> j) {
    final logo = j['logo_url'] as String? ?? '';
    final package = j['android_package'] as String? ?? '';
    return QuickLink(
      j['title'] as String? ?? '',
      j['url'] as String? ?? '',
      logo: logo.isEmpty ? null : resolveMediaUrl(logo),
      androidPackage: package.isEmpty ? null : package,
      fromAdmin: true,
    );
  }

  final String name;
  final String url;

  /// Web address of the service's icon, or a picture file the user picked; null shows the first letter.
  final String? logo;

  /// Android app opened instead of the site when installed.
  final String? androidPackage;

  /// Pinned for everyone from the admin panel: the user cannot remove it.
  final bool fromAdmin;

  QuickLink withLogo(String logo) => QuickLink(name, url, logo: logo, androidPackage: androidPackage);

  Map<String, String> toJson() => {'name': name, 'url': url, 'logo': ?logo, 'package': ?androidPackage};
}

/// Popular Uzbek services offered first in the picker, with icons checked to load as PNG.
const quickLinkPresets = [
  QuickLink('Uzum Market', 'https://uzum.uz', logo: 'https://uzum.uz/static/img/icons/apple-touch-icon.png', androidPackage: 'uz.uzum.app'),
  // The site has only a 16px favicon, so the icon comes from its Play Store page.
  QuickLink('Uzum Bank', 'https://uzumbank.uz',
      logo: 'https://play-lh.googleusercontent.com/0u3I6QX-_u6P6ghgBDfJj3IZuaLBdtaz8ruPyLLRaLFJxBUqG4KAjdnz7lDlBHzV7yQSUeWGbspqeeAbQ1ET6A=s180',
      androidPackage: 'uz.kapitalbank.android'),
  QuickLink('MyGov','https://my.gov.uz', logo: 'https://my.gov.uz/logo.png', androidPackage: 'uz.uzinfocom.mygov'),
  QuickLink('Click', 'https://click.uz', logo: 'https://click.uz/apple-touch-icon.png', androidPackage: 'air.com.ssdsoftwaresolutions.clickuz'),
  QuickLink('Payme', 'https://payme.uz', logo: 'https://cdn.payme.uz/payme-logos/ico/p/1/apple-touch-icon.png', androidPackage: 'uz.dida.payme'),
  QuickLink('Yandex Go', 'https://go.yandex', logo: 'https://go.yandex/apple-touch-icon-180x180.png', androidPackage: 'ru.yandex.taxi'),
];

const _nativeChannel = MethodChannel('uz.sado.app/privacy');

/// Links admins pin for everyone, in paid order. A failure (offline, no server) shows none and is not
/// cached, so the next visit to the hub asks again.
final adminQuickLinksProvider = FutureProvider.autoDispose<List<QuickLink>>((ref) async {
  final keep = ref.keepAlive();
  final expiry = Timer(_adminLinksCacheFor, keep.close);
  ref.onDispose(expiry.cancel);
  final api = ref.watch(sadoApiProvider);
  if (!api.configured) return const [];
  try {
    return [for (final j in await api.quickLinks()) QuickLink.fromAdmin(j)];
  } on ApiException catch (error) {
    debugPrint('admin quick links unavailable: $error');
    keep.close();
    rethrow;
  }
});

/// Best icon a page declares: an apple-touch-icon, else the biggest PNG/ICO icon; null when it declares none.
/// SVG icons are skipped: Image.network cannot draw them.
String? pickIconHref(String html) {
  String? best;
  var bestScore = -1;
  for (final match in RegExp(r'<link\b[^>]*>', caseSensitive: false).allMatches(html)) {
    final tag = match.group(0)!;
    final rel = _attr(tag, 'rel')?.toLowerCase() ?? '';
    final href = _attr(tag, 'href');
    if (href == null || !rel.contains('icon') || rel.contains('mask') || href.toLowerCase().contains('.svg')) continue;
    final size = int.tryParse(RegExp(r'(\d+)x').firstMatch(_attr(tag, 'sizes') ?? '')?.group(1) ?? '') ?? 16;
    final score = (rel.contains('apple-touch') ? 1000 : 0) + size;
    if (score > bestScore) {
      best = href;
      bestScore = score;
    }
  }
  return best;
}

/// An HTML attribute, quoted or not (minified pages drop the quotes).
String? _attr(String tag, String name) {
  final match = RegExp('\\b$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', caseSensitive: false).firstMatch(tag);
  return match == null ? null : match.group(1) ?? match.group(2) ?? match.group(3);
}

/// Icon URL of a site from its home page, falling back to /favicon.ico (the letter shows if that fails too).
Future<String> findSiteLogo(String pageUrl) async {
  final page = Uri.parse(pageUrl);
  try {
    final response = await Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      responseType: ResponseType.plain,
      headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 13; Mobile)'},
    )).getUri<String>(page);
    return page.resolve(pickIconHref(response.data ?? '') ?? '/favicon.ico').toString();
  } on DioException catch (error) {
    debugPrint('site logo lookup failed: ${error.message}');
    return page.resolve('/favicon.ico').toString();
  }
}

/// Web link for what the user typed ("uzum.uz" becomes "https://uzum.uz"), or null when it is not a web address.
String? normalizeQuickUrl(String input) {
  final text = input.trim();
  if (text.isEmpty || text.contains(' ')) return null;
  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || !uri.host.contains('.')) return null;
  return uri.toString();
}

bool _isWebLogo(String logo) => logo.startsWith('http://') || logo.startsWith('https://');

final quickLinksProvider = NotifierProvider<QuickLinksNotifier, List<QuickLink>>(QuickLinksNotifier.new);

/// The user's own pinned quick links, remembered on this phone.
class QuickLinksNotifier extends Notifier<List<QuickLink>> {
  static const _key = 'hubQuickLinks';

  @override
  List<QuickLink> build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    if (raw == null) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return [
        for (final entry in data)
          if (entry case {'name': final String name, 'url': final String url})
            QuickLink(name, url, logo: entry['logo'] as String?, androidPackage: entry['package'] as String?),
      ];
    } on FormatException catch (error) {
      debugPrint('quick links unreadable: $error');
      return const [];
    }
  }

  /// False when the row is full or the link is already pinned.
  bool add(QuickLink link) {
    if (state.length >= maxQuickLinks || state.any((l) => l.url == link.url)) return false;
    _save([...state, link]);
    return true;
  }

  void remove(QuickLink link) {
    _save([for (final l in state) if (l.url != link.url) l]);
    final logo = link.logo;
    if (logo != null && !_isWebLogo(logo)) unawaited(_deletePicture(logo));
  }

  void setLogo(String url, String logo) => _save([for (final l in state) l.url == url ? l.withLogo(logo) : l]);

  void _save(List<QuickLink> links) {
    ref.read(sharedPreferencesProvider).setString(_key, jsonEncode([for (final l in links) l.toJson()]));
    state = links;
  }
}

Future<void> _deletePicture(String path) async {
  try {
    await File(path).delete();
  } on FileSystemException catch (error) {
    debugPrint('quick link picture not deleted: $error');
  }
}

/// A new file path for a quick link's picture in the app's files, ending in [ext].
Future<String> _newPicturePath(String ext) async {
  final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/quick_links');
  await dir.create(recursive: true);
  return '${dir.path}/${DateTime.now().microsecondsSinceEpoch}$ext';
}

/// A gallery picture copied into the app's files (the picker's copy lives in the cache); null when none was picked.
Future<String?> _pickPicture() async {
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 256, maxHeight: 256, imageQuality: 90);
  if (picked == null) return null;
  final dot = picked.path.lastIndexOf('.');
  return (await File(picked.path).copy(await _newPicturePath(dot < 0 ? '.jpg' : picked.path.substring(dot)))).path;
}

/// Apps installed on this phone (Android), by name.
Future<List<({String package, String label})>> _phoneApps() async {
  final apps = await _nativeChannel.invokeListMethod<Map<Object?, Object?>>('installedApps') ?? const [];
  return [for (final a in apps) (package: a['package'] as String, label: a['label'] as String)];
}

final _appIcons = <String, Future<Uint8List?>>{};

Future<Uint8List?> _appIcon(String package) =>
    _appIcons[package] ??= _nativeChannel.invokeMethod<Uint8List>('appIcon', {'package': package});

/// A phone app as a quick link: opens the app, or its Play Store page once it is uninstalled.
Future<QuickLink> _phoneAppLink(({String package, String label}) app) async {
  final icon = await _appIcon(app.package);
  String? logo;
  if (icon != null) {
    final file = File(await _newPicturePath('.png'));
    await file.writeAsBytes(icon);
    logo = file.path;
  }
  return QuickLink(app.label, 'https://play.google.com/store/apps/details?id=${app.package}', logo: logo, androidPackage: app.package);
}

/// The service's app when it is installed (Android), otherwise its site.
Future<void> openQuickLink(BuildContext context, QuickLink link) async {
  // Links pinned before packages were saved find theirs through the matching preset.
  final package = link.androidPackage ?? quickLinkPresets.where((p) => p.url == link.url).firstOrNull?.androidPackage;
  var opened = false;
  try {
    if (package != null && Platform.isAndroid) {
      opened = await _nativeChannel.invokeMethod<bool>('openApp', {'package': package}) ?? false;
    }
    if (!opened) opened = await launchUrl(Uri.parse(link.url), mode: LaunchMode.externalApplication);
  } on PlatformException catch (error) {
    debugPrint('quick link failed: $error');
  }
  if (!opened && context.mounted) showToast(context, context.t('quick_open_failed'));
}

/// Picker for a new quick link: a preset or a name, address and picture of the user's own.
Future<void> addQuickLink(BuildContext context, WidgetRef ref) async {
  final link = await showModalBottomSheet<QuickLink>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _AddQuickLinkSheet(),
  );
  if (link == null || !context.mounted) return;
  final links = ref.read(quickLinksProvider.notifier);
  final added = links.add(link);
  showToast(context, context.t(added ? 'quick_added' : 'quick_exists'));
  // The tile shows the letter until the site's icon is found.
  if (added && link.logo == null) links.setLogo(link.url, await findSiteLogo(link.url));
}

Future<void> confirmRemoveQuickLink(BuildContext context, WidgetRef ref, QuickLink link) async {
  final s = context.s;
  final remove = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(link.name),
      content: Text(s.t('quick_remove')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(s.t('cancel'))),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(s.t('delete'))),
      ],
    ),
  );
  if (remove == true) ref.read(quickLinksProvider.notifier).remove(link);
}

class _AddQuickLinkSheet extends ConsumerStatefulWidget {
  const _AddQuickLinkSheet();

  @override
  ConsumerState<_AddQuickLinkSheet> createState() => _AddQuickLinkSheetState();
}

/// Room under the address field for the add button and the sheet's bottom padding.
const _belowFields = 96.0;

class _AddQuickLinkSheetState extends ConsumerState<_AddQuickLinkSheet> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  String? _urlError;
  String? _picture;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _choosePicture() async {
    try {
      final path = await _pickPicture();
      if (path != null && mounted) setState(() => _picture = path);
    } on PlatformException catch (error) {
      debugPrint('quick link picture not picked: $error');
    } on FileSystemException catch (error) {
      debugPrint('quick link picture not saved: $error');
    }
  }

  Future<void> _choosePhoneApp() async {
    final link = await showModalBottomSheet<QuickLink>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const _PhoneAppsSheet(),
    );
    if (link != null && mounted) Navigator.pop(context, link);
  }

  void _saveOwn() {
    final url = normalizeQuickUrl(_url.text);
    if (url == null) return setState(() => _urlError = context.t('quick_bad_url'));
    final name = _name.text.trim();
    Navigator.pop(context, QuickLink(name.isEmpty ? Uri.parse(url).host : name, url, logo: _picture));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final pinned = {
      for (final l in ref.watch(quickLinksProvider)) l.url,
      for (final l in ref.watch(adminQuickLinksProvider).value ?? const <QuickLink>[]) l.url,
    };
    final presets = [for (final p in quickLinkPresets) if (!pinned.contains(p.url)) p];
    final preview = QuickLink(_name.text.trim().isEmpty ? '+' : _name.text.trim(), '', logo: _picture);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s.t('quick_add'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (Platform.isAndroid)
                ListTile(
                  leading: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                    child: Icon(Icons.apps_rounded, color: Theme.of(context).colorScheme.primary),
                  ),
                  title: Text(s.t('quick_phone_apps')),
                  subtitle: Text(s.t('quick_phone_apps_hint')),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _choosePhoneApp,
                ),
              for (final preset in presets)
                ListTile(
                  leading: QuickLinkBadge(link: preset, size: 42),
                  title: Text(preset.name),
                  subtitle: Text(Uri.parse(preset.url).host),
                  onTap: () => Navigator.pop(context, preset),
                ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(s.t('quick_custom'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          button: true,
                          label: s.t('quick_image'),
                          child: InkWell(
                            onTap: _choosePicture,
                            borderRadius: BorderRadius.circular(16),
                            child: Column(
                              children: [
                                _picture == null
                                    ? Container(
                                        width: 56,
                                        height: 56,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(17),
                                          border: Border.all(color: Theme.of(context).dividerColor),
                                        ),
                                        child: Icon(Icons.add_photo_alternate_outlined, color: Theme.of(context).hintColor),
                                      )
                                    : QuickLinkBadge(link: preview, size: 56),
                                const SizedBox(height: 4),
                                SizedBox(
                                  width: 64,
                                  child: Text(s.t('quick_image'), textAlign: TextAlign.center, maxLines: 2,
                                      style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor)),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _name,
                            maxLength: 24,
                            // Scroll the address field and the add button below into view with it, above the keyboard.
                            scrollPadding: const EdgeInsets.only(bottom: _belowFields + 76),
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(labelText: s.t('quick_name'), border: const OutlineInputBorder()),
                          ),
                        ),
                      ],
                    ),
                    TextField(
                      controller: _url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      // The add button stays visible above the keyboard; its done key adds too.
                      scrollPadding: const EdgeInsets.only(bottom: _belowFields),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _saveOwn(),
                      onChanged: (_) => setState(() => _urlError = null),
                      decoration: InputDecoration(labelText: s.t('quick_url'), hintText: 'uzum.uz', errorText: _urlError, border: const OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _saveOwn, child: Text(s.t('add'))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The phone's apps with a search box; picking one returns it as a quick link.
class _PhoneAppsSheet extends ConsumerStatefulWidget {
  const _PhoneAppsSheet();

  @override
  ConsumerState<_PhoneAppsSheet> createState() => _PhoneAppsSheetState();
}

class _PhoneAppsSheetState extends ConsumerState<_PhoneAppsSheet> {
  late final Future<List<({String package, String label})>> _apps = _phoneApps();
  var _query = '';
  var _saving = false;

  Future<void> _pick(({String package, String label}) app) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final link = await _phoneAppLink(app);
      if (mounted) Navigator.pop(context, link);
    } on Exception catch (error) {
      // PlatformException or FileSystemException: the tile still works with its letter.
      debugPrint('phone app icon not saved: $error');
      if (mounted) Navigator.pop(context, QuickLink(app.label, 'https://play.google.com/store/apps/details?id=${app.package}', androidPackage: app.package));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final pinned = {for (final l in ref.watch(quickLinksProvider)) ?l.androidPackage};
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                onChanged: (text) => setState(() => _query = text.trim().toLowerCase()),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: s.t('quick_phone_apps'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            if (_saving) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: FutureBuilder(
                future: _apps,
                builder: (context, snapshot) {
                  if (snapshot.hasError) return Center(child: Text(s.t('quick_open_failed')));
                  final all = snapshot.data;
                  if (all == null) return const Center(child: CircularProgressIndicator());
                  final apps = [for (final a in all) if (!pinned.contains(a.package) && a.label.toLowerCase().contains(_query)) a];
                  return ListView.builder(
                    itemCount: apps.length,
                    itemBuilder: (context, i) => ListTile(
                      leading: _PhoneAppIcon(package: apps[i].package),
                      title: Text(apps[i].label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => _pick(apps[i]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneAppIcon extends StatelessWidget {
  const _PhoneAppIcon({required this.package});

  final String package;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: 42,
        child: FutureBuilder(
          future: _appIcon(package),
          builder: (context, snapshot) => switch (snapshot.data) {
            final Uint8List png => ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(png, gaplessPlayback: true)),
            _ => const SizedBox.shrink(),
          },
        ),
      );
}

/// The service's logo as an app icon: the picture fills a rounded square with a soft edge and shadow.
/// Without a picture, the first letter on a gradient coloured by the name.
class QuickLinkBadge extends StatelessWidget {
  const QuickLinkBadge({super.key, required this.link, this.size = 58});

  final QuickLink link;
  final double size;

  static const _colors = [Color(0xFF7C5CFF), Color(0xFF2F7BFF), Color(0xFF1FAE6B), Color(0xFFFF6B45), Color(0xFFF2457D), Color(0xFF14B3A0)];

  @override
  Widget build(BuildContext context) {
    final name = link.name;
    final color = _colors[name.codeUnits.fold(0, (a, b) => a + b) % _colors.length];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(size * 0.28);
    final letter = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, 0.18)!, color],
        ),
      ),
      child: Center(
        child: Text(
          name.isEmpty ? '?' : name.characters.first.toUpperCase(),
          style: TextStyle(color: Colors.white, fontSize: size * 0.44, fontWeight: FontWeight.w800),
        ),
      ),
    );
    final logo = link.logo;
    // The letter stays until the first frame is decoded (loadingBuilder reports "done" before the bytes start).
    Widget frame(BuildContext _, Widget child, int? frame, bool sync) => frame == null && !sync ? letter : child;
    Widget broken(BuildContext _, Object _, StackTrace? _) => letter;
    final picture = logo == null
        ? letter
        : _isWebLogo(logo)
            ? Image.network(logo, fit: BoxFit.cover, filterQuality: FilterQuality.medium, frameBuilder: frame, errorBuilder: broken)
            : Image.file(File(logo), fit: BoxFit.cover, filterQuality: FilterQuality.medium, frameBuilder: frame, errorBuilder: broken);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // Transparent icons sit on the card colour, so no white box shows around full-bleed ones.
        color: dark ? const Color(0xFF2B2F36) : Colors.white,
        borderRadius: radius,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10), blurRadius: size * 0.16, offset: Offset(0, size * 0.04))],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.07), width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox.expand(child: picture),
    );
  }
}
