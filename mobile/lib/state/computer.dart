import 'dart:convert';

/// How to reach another phone that holds the Cortex Wake gateway (a power-button robot).
/// The token authenticates this app to that phone. It lives only in secure storage.
class WakeGateway {
  const WakeGateway({required this.address, required this.token});

  /// e.g. http://100.64.0.7:8780 (the gateway phone's Tailscale address)
  final String address;
  final String token;

  Map<String, dynamic> toJson() => {'address': address, 'token': token};

  static WakeGateway? fromJson(Object? j) {
    if (j is! Map) return null;
    final a = j['address'], t = j['token'];
    if (a is! String || t is! String || a.isEmpty || t.isEmpty) return null;
    return WakeGateway(address: a, token: t);
  }
}

/// One computer that this phone controls. Stored as JSON in flutter_secure_storage
/// (it holds the device token and the addresses), never in plain preferences.
class Computer {
  const Computer({
    required this.id,
    required this.name,
    required this.endpoints,
    required this.token,
    this.allowLanHttp = false,
    this.wakeVia,
    this.wakeGateway,
    this.rustdeskId,
  });

  final String id;
  final String name;

  /// Ordered: the first is tried first (usually the Tailscale address), then the LAN one.
  final List<String> endpoints;
  final String token;

  /// The owner confirmed that LAN addresses are their own home network (plain http,
  /// not encrypted). Without this, only Tailscale/loopback addresses are accepted.
  final bool allowLanHttp;

  /// Name of ANOTHER computer in this app whose agent can wake this one (Wake-on-LAN).
  final String? wakeVia;

  /// Optional Cortex Wake gateway (phone + ESP32 + servo).
  final WakeGateway? wakeGateway;

  /// The RustDesk ID the owner typed in (never the password).
  final String? rustdeskId;

  Computer copyWith({
    String? name,
    List<String>? endpoints,
    String? token,
    bool? allowLanHttp,
    Object? wakeVia = _keep,
    Object? wakeGateway = _keep,
    Object? rustdeskId = _keep,
  }) => Computer(
    id: id,
    name: name ?? this.name,
    endpoints: endpoints ?? this.endpoints,
    token: token ?? this.token,
    allowLanHttp: allowLanHttp ?? this.allowLanHttp,
    wakeVia: identical(wakeVia, _keep) ? this.wakeVia : wakeVia as String?,
    wakeGateway: identical(wakeGateway, _keep)
        ? this.wakeGateway
        : wakeGateway as WakeGateway?,
    rustdeskId: identical(rustdeskId, _keep)
        ? this.rustdeskId
        : rustdeskId as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'endpoints': endpoints,
    'token': token,
    'allow_lan_http': allowLanHttp,
    if (wakeVia != null) 'wake_via': wakeVia,
    if (wakeGateway != null) 'wake_gateway': wakeGateway!.toJson(),
    if (rustdeskId != null) 'rustdesk_id': rustdeskId,
  };

  static Computer? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], token = j['token'];
    final eps = j['endpoints'];
    if (id is! String ||
        name is! String ||
        token is! String ||
        eps is! List ||
        id.isEmpty ||
        token.isEmpty) {
      return null;
    }
    final endpoints = [
      for (final e in eps)
        if (e is String && e.isNotEmpty) e,
    ];
    if (endpoints.isEmpty) return null;
    return Computer(
      id: id,
      name: name,
      endpoints: endpoints,
      token: token,
      allowLanHttp: j['allow_lan_http'] == true,
      wakeVia: j['wake_via'] is String && (j['wake_via'] as String).isNotEmpty
          ? j['wake_via'] as String
          : null,
      wakeGateway: WakeGateway.fromJson(j['wake_gateway']),
      rustdeskId:
          j['rustdesk_id'] is String && (j['rustdesk_id'] as String).isNotEmpty
          ? j['rustdesk_id'] as String
          : null,
    );
  }

  static const Object _keep = Object();
}

/// Reads the stored list. Garbage entries are dropped, never trusted.
List<Computer> decodeComputers(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (Computer.fromJson(e) case final c?) c,
    ];
  } on FormatException {
    return const [];
  }
}

String encodeComputers(List<Computer> list) =>
    jsonEncode([for (final c in list) c.toJson()]);
