/// Server data for online shops, warehouse, hub ads and admin lists (JSON shapes: server/app/market.py).
library;

import '../config.dart';

enum ListingStatus { awaitingPayment, pending, approved, rejected, closed }

enum AdStatus { awaitingPayment, pendingReview, approved, rejected }

enum StockKind { stockIn, sale, stockReturn, adjust }

ListingStatus _listingStatus(Object? raw) => switch (raw) {
      'awaiting_payment' => ListingStatus.awaitingPayment,
      'approved' => ListingStatus.approved,
      'rejected' => ListingStatus.rejected,
      'closed' => ListingStatus.closed,
      _ => ListingStatus.pending,
    };

AdStatus _adStatus(Object? raw) => switch (raw) {
      'pending_review' => AdStatus.pendingReview,
      'approved' => AdStatus.approved,
      'rejected' => AdStatus.rejected,
      _ => AdStatus.awaitingPayment,
    };

String stockKindName(StockKind kind) => switch (kind) {
      StockKind.stockIn => 'in',
      StockKind.sale => 'sale',
      StockKind.stockReturn => 'return',
      StockKind.adjust => 'adjust',
    };

StockKind _stockKind(Object? raw) => switch (raw) {
      'sale' => StockKind.sale,
      'return' => StockKind.stockReturn,
      'adjust' => StockKind.adjust,
      _ => StockKind.stockIn,
    };

DateTime? _date(Object? raw) => raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

/// Server uploads come as `/media/<name>`; external links are already absolute.
String resolveMediaUrl(String url) => url.startsWith('/media/') ? '${AppConfig.apiUrl}$url' : url;

/// Product categories (server/app/market.py CATEGORIES); labels are translated as `cat_<key>`.
const productCategories = [
  'electronics',
  'phones',
  'clothes',
  'shoes',
  'beauty',
  'home',
  'kitchen',
  'kids',
  'food',
  'flowers',
  'sport',
  'auto',
  'books',
  'health',
  'other',
];

class Profile {
  const Profile({required this.firstName, required this.lastName, required this.username, required this.phone});

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        firstName: json['first_name'] as String? ?? '',
        lastName: json['last_name'] as String? ?? '',
        username: json['username'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
      );

  final String firstName;
  final String lastName;
  final String username;
  final String phone;

  String get name => '$firstName $lastName'.trim();

  Map<String, dynamic> toJson() => {'first_name': firstName, 'last_name': lastName, 'username': username, 'phone': phone};
}

class Shop {
  const Shop({
    required this.id,
    required this.name,
    required this.description,
    required this.region,
    required this.phone,
    required this.telegram,
    required this.logoUrl,
    this.productCount,
    this.status,
    this.rejectReason,
    this.priceUzs = 0,
    this.hasReceipt = false,
    this.closeRequested = false,
    this.closeReason,
    this.owner,
    this.products = const [],
  });

  factory Shop.fromJson(Map<String, dynamic> json) => Shop(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        region: json['region'] as String,
        phone: json['phone'] as String? ?? '',
        telegram: json['telegram'] as String? ?? '',
        logoUrl: json['logo_url'] as String? ?? '',
        productCount: json['product_count'] as int?,
        status: json.containsKey('status') ? _listingStatus(json['status']) : null,
        rejectReason: json['reject_reason'] as String?,
        priceUzs: json['price_uzs'] as int? ?? 0,
        hasReceipt: json['has_receipt'] as bool? ?? false,
        closeRequested: json['close_requested'] as bool? ?? false,
        closeReason: json['close_reason'] as String?,
        owner: json['owner'] is Map<String, dynamic> ? Profile.fromJson(json['owner'] as Map<String, dynamic>) : null,
        products: [for (final p in json['products'] as List? ?? const []) Product.fromJson(p as Map<String, dynamic>)],
      );

  final String id;
  final String name;
  final String description;
  final String region;
  final String phone;
  final String telegram;
  final String logoUrl;
  final int? productCount;

  /// Only for the owner and admins.
  final ListingStatus? status;
  final String? rejectReason;
  final int priceUzs;
  final bool hasReceipt;
  final bool closeRequested;
  final String? closeReason;

  /// Admin lists: the owner's shared profile, if any.
  final Profile? owner;
  final List<Product> products;
}

class ShopDraft {
  const ShopDraft({required this.name, required this.description, required this.region, required this.phone, required this.telegram, required this.logoUrl});

  final String name;
  final String description;
  final String region;
  final String phone;
  final String telegram;
  final String logoUrl;

  Map<String, dynamic> toJson() =>
      {'name': name, 'description': description, 'region': region, 'phone': phone, 'telegram': telegram, 'logo_url': logoUrl};
}

/// "My shops" with the price of opening one more.
class MyShops {
  const MyShops({required this.shops, required this.freeLimit, required this.nextShopPriceUzs});

  factory MyShops.fromJson(Map<String, dynamic> json) => MyShops(
        shops: [for (final s in json['shops'] as List) Shop.fromJson(s as Map<String, dynamic>)],
        freeLimit: json['free_limit'] as int,
        nextShopPriceUzs: json['next_shop_price_uzs'] as int,
      );

  final List<Shop> shops;
  final int freeLimit;
  final int nextShopPriceUzs;
}

class MediaItem {
  const MediaItem({required this.isVideo, required this.url});

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(isVideo: json['type'] == 'video', url: json['url'] as String);

  final bool isVideo;

  /// As stored ("/media/..." or https); use [resolveMediaUrl] to load it.
  final String url;

  Map<String, dynamic> toJson() => {'type': isVideo ? 'video' : 'image', 'url': url};
}

class Product {
  const Product({
    required this.id,
    required this.title,
    required this.description,
    required this.priceUzs,
    required this.active,
    this.category = '',
    this.sku = '',
    this.oldPriceUzs,
    this.media = const [],
    this.stock = 0,
  });

  factory Product.fromJson(Map<String, dynamic> json) => Product(
        id: json['id'] as String,
        title: json['title'] as String,
        description: json['description'] as String? ?? '',
        priceUzs: json['price_uzs'] as int,
        active: json['active'] as bool? ?? true,
        category: json['category'] as String? ?? '',
        sku: json['sku'] as String? ?? '',
        oldPriceUzs: json['old_price_uzs'] as int?,
        media: [for (final m in json['media'] as List? ?? const []) MediaItem.fromJson(m as Map<String, dynamic>)],
        stock: json['stock'] as int? ?? 0,
      );

  final String id;
  final String title;
  final String description;
  final int priceUzs;
  final bool active;
  final String category;
  final String sku;
  final int? oldPriceUzs;
  final List<MediaItem> media;
  final int stock;

  /// First photo, for cards and lists.
  String get coverUrl => media.where((m) => !m.isVideo).map((m) => m.url).firstOrNull ?? '';

  /// Whole percent off the crossed-out price, or 0.
  int get discountPercent {
    final old = oldPriceUzs;
    if (old == null || old <= priceUzs || old == 0) return 0;
    return ((old - priceUzs) * 100 / old).round();
  }
}

class ProductDraft {
  const ProductDraft({
    required this.title,
    required this.description,
    required this.category,
    required this.sku,
    required this.priceUzs,
    required this.oldPriceUzs,
    required this.media,
    required this.active,
    this.initialStock = 0,
  });

  final String title;
  final String description;
  final String category;
  final String sku;
  final int priceUzs;
  final int? oldPriceUzs;
  final List<MediaItem> media;
  final bool active;

  /// New products only: units received into the warehouse right away.
  final int initialStock;

  Map<String, dynamic> toJson({bool isNew = false}) => {
        'title': title,
        'description': description,
        'category': category,
        'sku': sku,
        'price_uzs': priceUzs,
        'old_price_uzs': oldPriceUzs,
        'media': [for (final m in media) m.toJson()],
        'active': active,
        if (isNew) 'initial_stock': initialStock,
      };
}

class StockMovement {
  const StockMovement({
    required this.id,
    required this.productTitle,
    required this.kind,
    required this.quantity,
    required this.unitPriceUzs,
    required this.note,
    required this.createdAt,
  });

  factory StockMovement.fromJson(Map<String, dynamic> json) => StockMovement(
        id: json['id'] as int,
        productTitle: json['product_title'] as String,
        kind: _stockKind(json['kind']),
        quantity: json['quantity'] as int,
        unitPriceUzs: json['unit_price_uzs'] as int? ?? 0,
        note: json['note'] as String? ?? '',
        createdAt: _date(json['created_at']),
      );

  final int id;
  final String productTitle;
  final StockKind kind;

  /// Signed change of stock.
  final int quantity;
  final int unitPriceUzs;
  final String note;
  final DateTime? createdAt;
}

class ShopStats {
  const ShopStats({
    required this.products,
    required this.activeProducts,
    required this.stockUnits,
    required this.stockValueUzs,
    required this.revenueTotalUzs,
    required this.unitsSoldTotal,
    required this.revenue30dUzs,
    required this.unitsSold30d,
    required this.lowStock,
  });

  factory ShopStats.fromJson(Map<String, dynamic> json) => ShopStats(
        products: json['products'] as int,
        activeProducts: json['active_products'] as int,
        stockUnits: json['stock_units'] as int,
        stockValueUzs: json['stock_value_uzs'] as int,
        revenueTotalUzs: json['revenue_total_uzs'] as int,
        unitsSoldTotal: json['units_sold_total'] as int,
        revenue30dUzs: json['revenue_30d_uzs'] as int,
        unitsSold30d: json['units_sold_30d'] as int,
        lowStock: [for (final p in json['low_stock'] as List) ((p as Map)['title'] as String, p['stock'] as int)],
      );

  final int products;
  final int activeProducts;
  final int stockUnits;
  final int stockValueUzs;
  final int revenueTotalUzs;
  final int unitsSoldTotal;
  final int revenue30dUzs;
  final int unitsSold30d;
  final List<(String title, int stock)> lowStock;
}

class Ad {
  const Ad({
    required this.id,
    required this.title,
    required this.text,
    required this.isVideo,
    required this.mediaUrl,
    required this.linkUrl,
    this.regions = const [],
    this.days = 0,
    this.priceUzs = 0,
    this.status = AdStatus.approved,
    this.hasReceipt = false,
    this.rejectReason,
    this.endsAt,
  });

  factory Ad.fromJson(Map<String, dynamic> json) => Ad(
        id: json['id'] as String,
        title: json['title'] as String,
        text: json['text'] as String? ?? '',
        isVideo: json['media_type'] == 'video',
        mediaUrl: json['media_url'] as String,
        linkUrl: json['link_url'] as String? ?? '',
        regions: [for (final r in json['regions'] as List? ?? const []) r as String],
        days: json['days'] as int? ?? 0,
        priceUzs: json['price_uzs'] as int? ?? 0,
        status: json.containsKey('status') ? _adStatus(json['status']) : AdStatus.approved,
        hasReceipt: json['has_receipt'] as bool? ?? false,
        rejectReason: json['reject_reason'] as String?,
        endsAt: _date(json['ends_at']),
      );

  final String id;
  final String title;
  final String text;
  final bool isVideo;
  final String mediaUrl;
  final String linkUrl;
  final List<String> regions;
  final int days;
  final int priceUzs;
  final AdStatus status;
  final bool hasReceipt;
  final String? rejectReason;
  final DateTime? endsAt;
}

class AdDraft {
  const AdDraft({required this.title, required this.text, required this.isVideo, required this.mediaUrl, required this.linkUrl, required this.regions, required this.days});

  final String title;
  final String text;
  final bool isVideo;
  final String mediaUrl;
  final String linkUrl;
  final List<String> regions;
  final int days;

  Map<String, dynamic> toJson() => {
        'title': title,
        'text': text,
        'media_type': isVideo ? 'video' : 'image',
        'media_url': mediaUrl,
        'link_url': linkUrl,
        'regions': regions,
        'days': days,
      };
}

class AdsConfig {
  const AdsConfig({required this.pricePerRegionDay, required this.maxDays, required this.cardNumber, required this.cardHolder, required this.extraShopPrice});

  factory AdsConfig.fromJson(Map<String, dynamic> json) => AdsConfig(
        pricePerRegionDay: json['price_per_region_day_uzs'] as int,
        maxDays: json['max_days'] as int,
        cardNumber: json['card_number'] as String? ?? '',
        cardHolder: json['card_holder'] as String? ?? '',
        extraShopPrice: json['extra_shop_price_uzs'] as int? ?? 0,
      );

  final int pricePerRegionDay;
  final int maxDays;
  final String cardNumber;
  final String cardHolder;
  final int extraShopPrice;
}

/// A row of the admin's customer list.
class AdminCustomer {
  const AdminCustomer({required this.id, required this.createdAt, required this.platform, required this.profile, required this.shops, required this.ads});

  factory AdminCustomer.fromJson(Map<String, dynamic> json) => AdminCustomer(
        id: json['id'] as String,
        createdAt: _date(json['created_at']),
        platform: json['platform'] as String? ?? '',
        profile: json['profile'] is Map<String, dynamic> ? Profile.fromJson(json['profile'] as Map<String, dynamic>) : null,
        shops: json['shops'] as int? ?? 0,
        ads: json['ads'] as int? ?? 0,
      );

  final String id;
  final DateTime? createdAt;
  final String platform;
  final Profile? profile;
  final int shops;
  final int ads;
}

/// YouTube video id of [url], or null when it is not a YouTube link.
String? youtubeId(String url) => RegExp(r'(?:youtube\.com/(?:watch\?v=|shorts/|embed/)|youtu\.be/)([\w-]{11})').firstMatch(url)?.group(1);
