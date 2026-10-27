import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
import 'market_models.dart';
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

/// Client of the Sado server (shops, ads, admin review). The app gets an anonymous,
/// device-bound customer account on first use; nothing from Telegram is sent.
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

  // ------------------------------------------------------------------ ads

  Future<AdsConfig> adsConfig() async => AdsConfig.fromJson(await _get('/v1/ads/config') as Map<String, dynamic>);

  Future<List<Ad>> activeAds(String region) async =>
      [for (final a in await _get('/v1/ads/active', query: {'region': region}) as List) Ad.fromJson(a as Map<String, dynamic>)];

  Future<List<Ad>> myAds() async => [for (final a in await _get('/v1/ads/mine') as List) Ad.fromJson(a as Map<String, dynamic>)];

  Future<Ad> createAd(AdDraft draft) async => Ad.fromJson(await _post('/v1/ads', data: draft.toJson()) as Map<String, dynamic>);

  Future<Ad> uploadReceipt(String adId, String filePath) async {
    final form = FormData.fromMap({'file': await MultipartFile.fromFile(filePath)});
    return Ad.fromJson(await _post('/v1/ads/$adId/receipt', data: form) as Map<String, dynamic>);
  }

  Future<void> cancelAd(String adId) => _delete('/v1/ads/$adId');

  // ------------------------------------------------------------------ admin

  Future<String?> adminKey() => _storage.read(key: _adminKey);

  Future<Map<String, String>> _adminHeaders() async {
    final key = await adminKey();
    if (key == null) throw ApiException('ADMIN_KEY_REQUIRED', 401);
    return {'X-Admin-Key': key};
  }

  Future<dynamic> _admin(String method, String path, {Object? data, Map<String, dynamic>? query, ResponseType? responseType}) async =>
      _send(method, path, data: data, query: query, auth: false, headers: await _adminHeaders(), responseType: responseType);

  /// Checks [key] with the server and remembers it; returns the admin's name.
  Future<String> adminLogin(String key) async {
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
