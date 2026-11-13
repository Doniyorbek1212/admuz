import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'gift_models.dart';
import 'market_models.dart';
import 'movie_models.dart';
import 'music_models.dart';
import 'place_models.dart';

/// Error from the Sado server, with its stable code (e.g. AD_NOT_FOUND) for localized messages.
class ApiException implements Exception {
  ApiException(this.code, [this.status]);

  final String code;
  final int? status;

  @override
  String toString() => 'ApiException($code, $status)';
}

final sadoApiProvider = Provider<SadoApi>((ref) => SadoApi());

/// Client of the Sado server (shops, ads, admin review, gifts). The app gets an anonymous,
/// device-bound customer account on first use. Telegram data goes only where the user acts:
/// a shared profile, or for gifts the user's own Telegram id (proven via the bot) and the recipient's id.
class SadoApi {
  SadoApi() : _dio = Dio(BaseOptions(baseUrl: AppConfig.apiUrl, connectTimeout: _timeout, receiveTimeout: _timeout, sendTimeout: _timeout));

  static const _timeout = Duration(seconds: 15);
  static const _storage = FlutterSecureStorage();
  static const _refreshKey = 'sado.api.refresh';
  static const _adminKey = 'sado.api.admin_key';

  final Dio _dio;
  String? _accessToken;
  Future<void>? _authenticating;

  bool get configured => AppConfig.apiUrl.isNotEmpty;

  // ------------------------------------------------------------------ auth

  Future<void> _ensureAuth() {
    if (_accessToken != null) return Future.value();
    return _authenticating ??= _authenticate().whenComplete(() => _authenticating = null);
  }

  Future<void> _authenticate() async {
    final refresh = await _storage.read(key: _refreshKey);
    if (refresh != null) {
      try {
        _store(await _post('/v1/auth/refresh', data: {'refresh_token': refresh}, auth: false));
        return;
      } on ApiException catch (error) {
        if (error.status != 401) rethrow;
      }
    }
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    _store(await _post('/v1/customers', data: {'platform': platform}, auth: false));
  }

  void _store(dynamic tokens) {
    final map = tokens as Map<String, dynamic>;
    _accessToken = map['access_token'] as String;
    _storage.write(key: _refreshKey, value: map['refresh_token'] as String);
  }

  Future<dynamic> _send(String method, String path, {Object? data, Map<String, dynamic>? query, bool auth = true, Map<String, String>? headers, ResponseType? responseType}) async {
    if (!configured) throw ApiException('SERVER_NOT_CONFIGURED');
    for (var attempt = 0; ; attempt++) {
      if (auth) await _ensureAuth();
      try {
        final response = await _dio.request<dynamic>(
          path,
          data: data,
          queryParameters: query,
          options: Options(
            method: method,
            responseType: responseType,
            headers: {if (auth && _accessToken != null) 'Authorization': 'Bearer $_accessToken', ...?headers},
          ),
        );
        return response.data;
      } on DioException catch (error) {
        final status = error.response?.statusCode;
        // Expired access token: get a new one once and retry.
        if (auth && status == 401 && attempt == 0 && headers == null) {
          _accessToken = null;
          continue;
        }
        throw _toApiException(error);
      }
    }
  }

  static ApiException _toApiException(DioException error) {
    final body = error.response?.data;
    final status = error.response?.statusCode;
    if (body is Map && body['detail'] is Map && (body['detail'] as Map)['code'] is String) {
      return ApiException((body['detail'] as Map)['code'] as String, status);
    }
    if (status == 422) return ApiException('VALIDATION_FAILED', status);
    if (error.response == null) return ApiException('NETWORK', null);
    return ApiException('SERVER_ERROR', status);
  }

  Future<dynamic> _get(String path, {Map<String, dynamic>? query}) => _send('GET', path, query: query);
  Future<dynamic> _post(String path, {Object? data, bool auth = true}) => _send('POST', path, data: data, auth: auth);
  Future<dynamic> _put(String path, Object data) => _send('PUT', path, data: data);
  Future<dynamic> _delete(String path) => _send('DELETE', path);

  // ------------------------------------------------------------------ profile and media

  /// Shares the Telegram name, username and phone (only after the user agreed).
  Future<void> saveProfile(Profile profile) => _put('/v1/customers/me/profile', profile.toJson());

  Future<void> deleteProfile() => _delete('/v1/customers/me/profile');

  /// Uploads a product photo or short video; returns it as stored on the server.
  Future<MediaItem> uploadMedia(String filePath, {void Function(double progress)? onProgress}) async {
    if (!configured) throw ApiException('SERVER_NOT_CONFIGURED');
    await _ensureAuth();
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/v1/media',
        data: FormData.fromMap({'file': await MultipartFile.fromFile(filePath)}),
        options: Options(headers: {'Authorization': 'Bearer $_accessToken'}, sendTimeout: const Duration(minutes: 3)),
        onSendProgress: onProgress == null ? null : (sent, total) => total > 0 ? onProgress(sent / total) : null,
      );
      return MediaItem.fromJson(response.data!);
    } on DioException catch (error) {
      throw _toApiException(error);
    }
  }

  // ------------------------------------------------------------------ shops

  Future<List<Shop>> shops(String region, {String query = ''}) async =>
      [for (final s in await _get('/v1/market/shops', query: {'region': region, if (query.isNotEmpty) 'q': query}) as List) Shop.fromJson(s as Map<String, dynamic>)];

  Future<Shop> shop(String id) async => Shop.fromJson(await _get('/v1/market/shops/$id') as Map<String, dynamic>);

  Future<MyShops> myShops() async => MyShops.fromJson(await _get('/v1/market/me/shops') as Map<String, dynamic>);

  Future<Shop> myShop(String id) async => Shop.fromJson(await _get('/v1/market/me/shops/$id') as Map<String, dynamic>);

  Future<Shop> createShop(ShopDraft draft) async => Shop.fromJson(await _post('/v1/market/me/shops', data: draft.toJson()) as Map<String, dynamic>);

  Future<Shop> updateShop(String id, ShopDraft draft) async => Shop.fromJson(await _put('/v1/market/me/shops/$id', draft.toJson()) as Map<String, dynamic>);

  Future<Shop> uploadShopReceipt(String id, String filePath) async {
    final form = FormData.fromMap({'file': await MultipartFile.fromFile(filePath)});
    return Shop.fromJson(await _post('/v1/market/me/shops/$id/receipt', data: form) as Map<String, dynamic>);
  }

  Future<Shop> requestShopClose(String id, String reason) async =>
      Shop.fromJson(await _post('/v1/market/me/shops/$id/close-request', data: {'reason': reason}) as Map<String, dynamic>);

  Future<Shop> cancelShopClose(String id) async => Shop.fromJson(await _delete('/v1/market/me/shops/$id/close-request') as Map<String, dynamic>);

  Future<Product> addProduct(String shopId, ProductDraft draft) async =>
      Product.fromJson(await _post('/v1/market/me/shops/$shopId/products', data: draft.toJson(isNew: true)) as Map<String, dynamic>);

  Future<Product> updateProduct(String id, ProductDraft draft) async =>
      Product.fromJson(await _put('/v1/market/me/products/$id', draft.toJson()) as Map<String, dynamic>);

  Future<void> deleteProduct(String id) => _delete('/v1/market/me/products/$id');

  /// Records a warehouse movement; [direction] matters only for adjustments (+1 found, -1 lost).
  Future<Product> moveStock(String productId, {required StockKind kind, required int quantity, int direction = 1, int unitPriceUzs = 0, String note = ''}) async =>
      Product.fromJson(await _post('/v1/market/me/products/$productId/stock', data: {
        'kind': stockKindName(kind),
        'quantity': quantity,
        'direction': direction,
        'unit_price_uzs': unitPriceUzs,
        'note': note,
      }) as Map<String, dynamic>);

  Future<List<StockMovement>> stockHistory(String shopId, {int? beforeId}) async => [
        for (final m in await _get('/v1/market/me/shops/$shopId/stock', query: {'before_id': ?beforeId}) as List)
          StockMovement.fromJson(m as Map<String, dynamic>),
      ];

  Future<ShopStats> shopStats(String shopId) async => ShopStats.fromJson(await _get('/v1/market/me/shops/$shopId/stats') as Map<String, dynamic>);

  // ------------------------------------------------------------------ region directory

  Future<List<PlaceRegion>> placeRegions() async =>
      [for (final r in await _get('/v1/places/regions') as List) PlaceRegion.fromJson(r as Map<String, dynamic>)];

  /// Count of places per category key in a region (or one district of it).
  Future<Map<String, int>> placeCounts(String region, {String? district}) async {
    final body = await _get('/v1/places/summary', query: {'region': region, 'district': ?district}) as Map<String, dynamic>;
    return (body['counts'] as Map).map((k, v) => MapEntry(k as String, v as int));
  }

  /// One page of places; with [lat]/[lon] the nearest come first and carry their distance.
  Future<PlacePage> places(String region, {String? district, String? category, String query = '', double? lat, double? lon, int offset = 0}) async =>
      PlacePage.fromJson(await _get('/v1/places', query: {
        'region': region,
        'district': ?district,
        'category': ?category,
        if (query.isNotEmpty) 'q': query,
        'lat': ?lat,
        'lon': ?lon,
        'offset': offset,
      }) as Map<String, dynamic>);

  Future<Place> place(String id) async => Place.fromJson(await _get('/v1/places/$id') as Map<String, dynamic>);

  /// Region and district (tuman) of a position, as the directory names them; nulls when no known place is near.
  Future<({String? region, String? district})> locate(double lat, double lon) async {
    final j = await _get('/v1/places/locate', query: {'lat': lat, 'lon': lon}) as Map<String, dynamic>;
    return (region: j['region'] as String?, district: j['district'] as String?);
  }

  // ------------------------------------------------------------------ movies

  /// Categories with something to watch, most titles first: (name, count).
  Future<List<(String, int)>> movieCategories({bool? series}) async => [
        for (final c in await _get('/v1/movies/categories', query: {'kind': ?_kind(series)}) as List)
          ((c as Map)['name'] as String, c['count'] as int),
      ];

  Future<MoviePage> movies({bool? series, String category = '', String query = '', int offset = 0}) async =>
      MoviePage.fromJson(await _get('/v1/movies', query: {
        'kind': ?_kind(series),
        if (category.isNotEmpty) 'category': category,
        if (query.isNotEmpty) 'q': query,
        'offset': offset,
      }) as Map<String, dynamic>);

  Future<MovieTitle> movie(String id) async => MovieTitle.fromJson(await _get('/v1/movies/$id') as Map<String, dynamic>);

  Future<MusicPage> music({String category = '', String query = '', int offset = 0}) async =>
      MusicPage.fromJson(await _get('/v1/music', query: {
        if (category.isNotEmpty) 'category': category,
        if (query.isNotEmpty) 'q': query,
        'offset': offset,
      }) as Map<String, dynamic>);

  static String? _kind(bool? series) => series == null ? null : (series ? 'series' : 'movie');

  // ------------------------------------------------------------------ gifts and balance

  /// The Telegram id this customer proved through the gifts bot, or null.
  Future<int?> telegramId() async => (await _get('/v1/telegram/me') as Map<String, dynamic>)['telegram_user_id'] as int?;

  Future<TelegramLinkCode> telegramLinkCode() async => TelegramLinkCode.fromJson(await _post('/v1/telegram/link') as Map<String, dynamic>);

  // ------------------------------------------------------------------ UZARO usernames

  /// This customer's UZARO @name (lowercase, no "@"), or null.
  Future<String?> myUzaroUsername() async => (await _get('/v1/usernames/me') as Map<String, dynamic>)['username'] as String?;

  /// Claims or renames; throws ApiException USERNAME_TAKEN / _PAID / _INVALID / _RESERVED / TELEGRAM_NOT_LINKED.
  Future<UzaroName> claimUzaroUsername(String username) async =>
      UzaroName.fromJson(await _put('/v1/usernames/me', {'username': username}) as Map<String, dynamic>);

  /// Price of a short (2–4 character) name: (status, price). Status is free / for_sale / closed / taken / yours.
  Future<(String, int)> uzaroUsernameQuote(String username) async {
    final json = await _get('/v1/usernames/check', query: {'username': username}) as Map<String, dynamic>;
    return (json['status'] as String, (json['price_uzs'] as num?)?.toInt() ?? 0);
  }

  /// Buys a short name for the UZARO balance; throws INSUFFICIENT_BALANCE / USERNAME_TAKEN / USERNAME_SALE_CLOSED.
  Future<UzaroName> buyUzaroUsername(String username) async =>
      UzaroName.fromJson(await _post('/v1/usernames/buy', data: {'username': username}) as Map<String, dynamic>);

  Future<void> releaseUzaroUsername() => _delete('/v1/usernames/me');

  /// Deletes this customer's UZARO data (profile, shops, links, balance access) on the server.
  Future<void> deleteMyData() => _delete('/v1/customers/me');

  /// Stores this account's Telegram contact-link token so people without a shared chat can open it.
  Future<void> setUzaroContact(String token, int expiresIn) => _put('/v1/usernames/me/contact', {'token': token, 'expires_in': expiresIn});

  Future<List<UzaroName>> searchUzaroUsernames(String query) async => [
        for (final item in (await _get('/v1/usernames/search', query: {'q': query}) as Map<String, dynamic>)['items'] as List)
          UzaroName.fromJson(item as Map<String, dynamic>),
      ];

  /// The UZARO @name of Telegram user [telegramId], or null.
  Future<String?> uzaroUsernameOf(int telegramId) async =>
      (await _get('/v1/usernames/of/$telegramId') as Map<String, dynamic>)['username'] as String?;

  /// Banned Telegram sources: usernames, and titles of entries known only by name.
  Future<({List<String> usernames, List<String> titles})> bannedChannels() async {
    final j = await _get('/v1/banned-channels') as Map<String, dynamic>;
    return (usernames: (j['usernames'] as List).cast<String>(), titles: (j['titles'] as List).cast<String>());
  }

  Future<List<GiftItem>> giftCatalog() async =>
      [for (final g in (await _get('/v1/gifts/catalog') as Map<String, dynamic>)['items'] as List) GiftItem.fromJson(g as Map<String, dynamic>)];

  /// Sends [giftId] to Telegram user [recipientId]; returns the balance left.
  Future<int> sendGift(String giftId, int recipientId, String text, {bool anonymous = false}) async {
    final result = await _post(
      '/v1/gifts/send',
      data: {'gift_id': giftId, 'recipient_telegram_id': recipientId, 'text': text, 'anonymous': anonymous},
    ) as Map<String, dynamic>;
    return result['balance_uzs'] as int? ?? 0;
  }

  /// Dearest gifts of each of these users/groups/channels (at most 100); ones without gifts are absent.
  Future<Map<int, GiftShowcase>> topGifts(List<int> ids) async {
    final json = await _get('/v1/gifts/top', query: {'ids': ids}) as Map<String, dynamic>;
    return {
      for (final entry in (json['items'] as Map<String, dynamic>).entries)
        int.parse(entry.key): GiftShowcase.fromJson(entry.value as Map<String, dynamic>),
    };
  }

  Future<ProfileGifts> userGifts(int telegramId) async =>
      ProfileGifts.fromJson(await _get('/v1/gifts/users/$telegramId') as Map<String, dynamic>);

  /// "#rrggbb" or "#rrggbb,#rrggbb"; null removes it.
  Future<void> setProfileBackground(String? background, String? pattern) =>
      _put('/v1/profile/background', {'background': background, 'pattern': pattern});

  /// Every gift this account received, newest first, and whether the profile hides them all.
  Future<(List<SentGift>, bool)> receivedGifts() async {
    final j = await _get('/v1/gifts/received') as Map<String, dynamic>;
    return ([for (final g in j['items'] as List) SentGift.fromJson(g as Map<String, dynamic>)], j['hide_all'] as bool? ?? false);
  }

  Future<void> setGiftHidden(String sentId, bool hidden) => _post('/v1/gifts/$sentId/visibility', data: {'hidden': hidden});

  /// The recipient hides (or shows) who sent a gift from people opening their profile.
  Future<void> setGiftSenderHidden(String sentId, bool hidden) => _post('/v1/gifts/$sentId/sender-visibility', data: {'hidden': hidden});

  /// Hides all received gifts, also later ones, from people opening this profile.
  Future<void> setAllGiftsHidden(bool hidden) => _put('/v1/profile/gifts-visibility', {'hidden': hidden});

  Future<Wallet> wallet() async => Wallet.fromJson(await _get('/v1/wallet') as Map<String, dynamic>);

  // ------------------------------------------------------------------ badges

  Future<BadgeOffer> badgeOffer() async => BadgeOffer.fromJson(await _get('/v1/badges/me') as Map<String, dynamic>);

  /// One more month of the badge (starts now or extends the running one) with this emoji; 0 = checkmark.
  Future<void> buyBadge(int emojiId) => _post('/v1/badges/buy', data: {'emoji_id': emojiId});

  /// Swaps the running badge's emoji, free.
  Future<void> changeBadge(int emojiId) => _put('/v1/badges/me', {'emoji_id': emojiId});

  /// Active badges of these Telegram users (at most 100): user id -> emoji id (0 = checkmark).
  Future<Map<int, int>> badgesOf(List<int> ids) async {
    final json = await _get('/v1/badges/of', query: {'ids': ids}) as Map<String, dynamic>;
    return {
      for (final entry in (json['badges'] as Map<String, dynamic>).entries) int.parse(entry.key): int.parse(entry.value as String),
    };
  }

  Future<void> requestTopup(int amountUzs, String receiptPath) async {
    final form = FormData.fromMap({'amount_uzs': amountUzs, 'receipt': await MultipartFile.fromFile(receiptPath)});
    await _post('/v1/wallet/topups', data: form);
  }

  /// A Payme order for [amountUzs]; returns the checkout page to open. The balance is credited when Payme pays.
  Future<Uri> paymeCheckout(int amountUzs) async {
    final body = await _post('/v1/wallet/payme', data: {'amount_uzs': amountUzs}) as Map<String, dynamic>;
    return Uri.parse(body['checkout_url'] as String);
  }

  // ------------------------------------------------------------------ usage statistics

  /// Reports [event] ("app_open", "hub_open", "movies_open") at most once per calendar day; never throws.
  Future<void> recordActivity(SharedPreferences prefs, String event) async {
    final now = DateTime.now();
    final today = '${now.year}-${now.month}-${now.day}';
    final key = 'activity.$event';
    if (!configured || prefs.getString(key) == today) return;
    try {
      await _post('/v1/activity', data: {'event': event});
      await prefs.setString(key, today);
    } on ApiException catch (error) {
      debugPrint('activity $event not recorded: $error');
    }
  }

  // ------------------------------------------------------------------ ads

  Future<AdsConfig> adsConfig() async => AdsConfig.fromJson(await _get('/v1/ads/config') as Map<String, dynamic>);

  Future<List<Ad>> activeAds(String region) async =>
      [for (final a in await _get('/v1/ads/active', query: {'region': region}) as List) Ad.fromJson(a as Map<String, dynamic>)];

  /// Sites and apps admins pin to everyone's hub "Tezkor" row, in their paid order.
  Future<List<Map<String, dynamic>>> quickLinks() async =>
      [for (final l in (await _get('/v1/quick-links') as Map<String, dynamic>)['items'] as List) l as Map<String, dynamic>];

  Future<List<Ad>> myAds() async => [for (final a in await _get('/v1/ads/mine') as List) Ad.fromJson(a as Map<String, dynamic>)];

  Future<Ad> createAd(AdDraft draft) async => Ad.fromJson(await _post('/v1/ads', data: draft.toJson()) as Map<String, dynamic>);

  Future<Ad> uploadReceipt(String adId, String filePath) async {
    final form = FormData.fromMap({'file': await MultipartFile.fromFile(filePath)});
    return Ad.fromJson(await _post('/v1/ads/$adId/receipt', data: form) as Map<String, dynamic>);
  }

  Future<void> cancelAd(String adId) => _delete('/v1/ads/$adId');

  /// Reports that a hub banner was seen ("view") or tapped ("click"); never throws.
  /// [learn] false: the tap is only counted, not used to learn the user's interests.
  Future<void> adEvent(String adId, String event, {bool learn = true}) async {
    if (!configured) return;
    try {
      await _post('/v1/ads/$adId/$event${learn ? '' : '?learn=false'}');
    } on ApiException catch (error) {
      debugPrint('ad $event not recorded: $error');
    }
  }

  // ------------------------------------------------------------------ interests (personalised ads)

  /// Tells the ads engine the user showed interest in [topic] ("open", "view", "search"); never throws.
  Future<void> sendInterest(String topic, String kind) async {
    if (!configured) return;
    try {
      await _post('/v1/interests', data: {
        'signals': [
          {'topic': topic, 'kind': kind},
        ],
      });
    } on ApiException catch (error) {
      debugPrint('interest $topic not recorded: $error');
    }
  }

  /// Deletes everything the ads engine learnt about this user.
  Future<void> clearInterests() => _delete('/v1/interests');

  // ------------------------------------------------------------------ admin

  Future<String?> adminKey() => _storage.read(key: _adminKey);

  Future<Map<String, String>> _adminHeaders() async {
    final key = await adminKey();
    if (key == null) throw ApiException('ADMIN_KEY_REQUIRED', 401);
    return {'X-Admin-Key': key};
  }

  Future<dynamic> _admin(String method, String path, {Object? data, Map<String, dynamic>? query, ResponseType? responseType}) async {
    try {
      return await _send(method, path, data: data, query: query, auth: false, headers: await _adminHeaders(), responseType: responseType);
    } on ApiException catch (error) {
      // Expired session or revoked key: forget it, so the next visit asks to sign in again.
      if (error.status == 401) await adminLogout();
      rethrow;
    }
  }

  /// Signs in with the panel login and password (a 12-hour session), or with a permanent key when [password] is
  /// empty; remembers the token and returns the admin's name.
  Future<String> adminLogin(String login, [String password = '']) async {
    var key = login;
    if (password.isNotEmpty) {
      final session = await _send('POST', '/v1/admin/login', data: {'login': login, 'password': password}, auth: false) as Map<String, dynamic>;
      key = session['token'] as String;
    }
    final me = await _send('GET', '/v1/admin/me', auth: false, headers: {'X-Admin-Key': key}) as Map<String, dynamic>;
    await _storage.write(key: _adminKey, value: key);
    return me['name'] as String;
  }

  Future<void> adminLogout() => _storage.delete(key: _adminKey);

  Future<Map<String, int>> adminSummary() async => (await _admin('GET', '/v1/admin/review/summary') as Map<String, dynamic>).cast<String, int>();

  Future<List<Ad>> adminAds({String status = 'pending_review'}) async =>
      [for (final a in await _admin('GET', '/v1/admin/ads', query: {'status': status}) as List) Ad.fromJson(a as Map<String, dynamic>)];

  Future<Uint8List> adminReceipt(String adId) async =>
      Uint8List.fromList(await _admin('GET', '/v1/admin/ads/$adId/receipt', responseType: ResponseType.bytes) as List<int>);

  Future<void> adminApproveAd(String adId) => _admin('POST', '/v1/admin/ads/$adId/approve');

  Future<void> adminRejectAd(String adId, String reason) => _admin('POST', '/v1/admin/ads/$adId/reject', data: {'reason': reason});

  Future<List<Shop>> adminShops({String status = 'pending'}) async =>
      [for (final s in await _admin('GET', '/v1/admin/shops', query: {'status': status}) as List) Shop.fromJson(s as Map<String, dynamic>)];

  Future<void> adminApproveShop(String shopId) => _admin('POST', '/v1/admin/shops/$shopId/approve');

  Future<void> adminRejectShop(String shopId, String reason) => _admin('POST', '/v1/admin/shops/$shopId/reject', data: {'reason': reason});

  Future<Uint8List> adminShopReceipt(String shopId) async =>
      Uint8List.fromList(await _admin('GET', '/v1/admin/shops/$shopId/receipt', responseType: ResponseType.bytes) as List<int>);

  Future<void> adminCloseShop(String shopId) => _admin('POST', '/v1/admin/shops/$shopId/close');

  Future<void> adminKeepShop(String shopId) => _admin('POST', '/v1/admin/shops/$shopId/keep');

  Future<(int total, List<AdminCustomer> users)> adminUsers({String query = '', int offset = 0}) async {
    final data = await _admin('GET', '/v1/admin/users', query: {if (query.isNotEmpty) 'q': query, 'offset': offset}) as Map<String, dynamic>;
    return (data['total'] as int, [for (final u in data['users'] as List) AdminCustomer.fromJson(u as Map<String, dynamic>)]);
  }
}
