import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'sync_transport.dart';

const p2pErrorBufferTooSmall = 12;

/// Stable Dart-side boundary for the native P2P library.
abstract interface class P2pBridge {
  int get protocolVersion;

  int get maxFrameBytes;

  Future<void> start({
    required String endpointId,
    required String groupId,
    String? endpointSecret,
  });

  Future<String> endpointId();

  Future<String> exportTicket();

  Future<int> connect(String ticket);

  Future<int?> accept({Duration timeout = const Duration(milliseconds: 250)});

  Future<Uint8List> request({
    required int connectionId,
    required Uint8List frame,
  });

  Future<Uint8List> receiveRequest({required int connectionId});

  Future<void> respond({
    required int connectionId,
    required Uint8List frame,
  });

  Future<void> close();
}

abstract interface class P2pNativeApi {
  int get protocolVersion;

  int get maxFrameBytes;

  int bind(Uint8List secret);

  String endpointId(int handle);

  String endpointTicket(int handle);

  int connect(int handle, String ticket);

  int? accept(int handle, Duration timeout);

  Uint8List request(int handle, int connectionId, Uint8List frame);

  Uint8List receiveRequest(int handle, int connectionId);

  void respond(int handle, int connectionId, Uint8List frame);

  void close(int handle);
}

class P2pNativeException implements Exception {
  const P2pNativeException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'P2pNativeException($code): $message';
}

class NativeP2pBridge implements P2pBridge {
  NativeP2pBridge({required this.api});

  final P2pNativeApi api;
  int? _handle;

  @override
  int get protocolVersion => api.protocolVersion;

  @override
  int get maxFrameBytes => api.maxFrameBytes;

  @override
  Future<void> start({
    required String endpointId,
    required String groupId,
    String? endpointSecret,
  }) async {
    if (_handle != null) return;
    final encoded = endpointSecret?.trim() ?? '';
    if (encoded.isEmpty) {
      throw const SyncTransportException(
        'P2P endpoint private key is not configured.',
        permanent: true,
      );
    }
    final secret = _decodeSecret(encoded);
    _handle = api.bind(secret);
    if (_handle == 0) {
      _handle = null;
      throw const SyncTransportException(
        'P2P endpoint could not be started.',
      );
    }
  }

  @override
  Future<String> endpointId() async => api.endpointId(_requireHandle());

  @override
  Future<String> exportTicket() async => api.endpointTicket(_requireHandle());

  @override
  Future<int> connect(String ticket) async =>
      api.connect(_requireHandle(), ticket);

  @override
  Future<int?> accept({Duration timeout = const Duration(milliseconds: 250)}) async =>
      api.accept(_requireHandle(), timeout);

  @override
  Future<Uint8List> request({
    required int connectionId,
    required Uint8List frame,
  }) async => api.request(_requireHandle(), connectionId, frame);

  @override
  Future<Uint8List> receiveRequest({required int connectionId}) async =>
      api.receiveRequest(_requireHandle(), connectionId);

  @override
  Future<void> respond({
    required int connectionId,
    required Uint8List frame,
  }) async {
    api.respond(_requireHandle(), connectionId, frame);
  }

  @override
  Future<void> close() async {
    final handle = _handle;
    _handle = null;
    if (handle != null) api.close(handle);
  }

  int _requireHandle() {
    final handle = _handle;
    if (handle == null) {
      throw const SyncTransportException(
        'P2P native bridge has not been started.',
        permanent: true,
      );
    }
    return handle;
  }

  static Uint8List _decodeSecret(String value) {
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      if (decoded.length != 32) throw const FormatException();
      return Uint8List.fromList(decoded);
    } on FormatException {
      throw const SyncTransportException(
        'P2P endpoint private key is invalid.',
        permanent: true,
      );
    }
  }
}

class UnavailableP2pBridge implements P2pBridge {
  const UnavailableP2pBridge();

  @override
  int get protocolVersion => 1;

  @override
  int get maxFrameBytes => 1024 * 1024;

  @override
  Future<void> start({
    required String endpointId,
    required String groupId,
    String? endpointSecret,
  }) async {
    throw const SyncTransportException(
      'P2P native bridge is not available on this build.',
      permanent: true,
    );
  }

  @override
  Future<String> endpointId() => _unavailable();

  @override
  Future<String> exportTicket() => _unavailable();

  @override
  Future<int> connect(String ticket) => _unavailable();

  @override
  Future<int?> accept({Duration timeout = const Duration(milliseconds: 250)}) =>
      _unavailable();

  @override
  Future<Uint8List> request({
    required int connectionId,
    required Uint8List frame,
  }) =>
      _unavailable();

  @override
  Future<Uint8List> receiveRequest({required int connectionId}) =>
      _unavailable();

  @override
  Future<void> respond({
    required int connectionId,
    required Uint8List frame,
  }) =>
      _unavailable();

  @override
  Future<void> close() async {}

  Future<T> _unavailable<T>() => Future<T>.error(
    const SyncTransportException(
      'P2P native bridge is not available on this build.',
      permanent: true,
    ),
  );
}

class FfiP2pNativeApi implements P2pNativeApi {
  FfiP2pNativeApi(this.library)
    : _protocolVersion = library.lookupFunction<_VersionNative, _VersionDart>(
        'easycalendar_p2p_protocol_version',
      ),
      _maxFrameBytes = library.lookupFunction<_VersionNative, _VersionDart>(
        'easycalendar_p2p_max_frame_bytes',
      ),
      _bind = library.lookupFunction<_BindNative, _BindDart>(
        'easycalendar_p2p_endpoint_bind',
      ),
      _idLength = library.lookupFunction<_IdLengthNative, _IdLengthDart>(
        'easycalendar_p2p_endpoint_id_len',
      ),
      _idCopy = library.lookupFunction<_IdCopyNative, _IdCopyDart>(
        'easycalendar_p2p_endpoint_id_copy',
      ),
      _ticket = library.lookupFunction<_TicketNative, _TicketDart>(
        'easycalendar_p2p_endpoint_ticket',
      ),
      _connect = library.lookupFunction<_ConnectNative, _ConnectDart>(
        'easycalendar_p2p_endpoint_connect_id',
      ),
      _accept = library.lookupFunction<_AcceptNative, _AcceptDart>(
        'easycalendar_p2p_endpoint_accept',
      ),
      _request = library.lookupFunction<_RequestNative, _RequestDart>(
        'easycalendar_p2p_endpoint_request',
      ),
      _receiveRequest = library.lookupFunction<
        _ReceiveRequestNative,
        _ReceiveRequestDart
      >('easycalendar_p2p_endpoint_receive_request'),
      _respond = library.lookupFunction<_RespondNative, _RespondDart>(
        'easycalendar_p2p_endpoint_respond',
      ),
      _close = library.lookupFunction<_CloseNative, _CloseDart>(
        'easycalendar_p2p_endpoint_close',
      );

  final ffi.DynamicLibrary library;
  final _VersionDart _protocolVersion;
  final _VersionDart _maxFrameBytes;
  final _BindDart _bind;
  final _IdLengthDart _idLength;
  final _IdCopyDart _idCopy;
  final _TicketDart _ticket;
  final _ConnectDart _connect;
  final _AcceptDart _accept;
  final _RequestDart _request;
  final _ReceiveRequestDart _receiveRequest;
  final _RespondDart _respond;
  final _CloseDart _close;

  static FfiP2pNativeApi? tryLoad() {
    try {
      return FfiP2pNativeApi(_openDefaultLibrary());
    } catch (_) {
      return null;
    }
  }

  @override
  int get protocolVersion => _protocolVersion();

  @override
  int get maxFrameBytes => _maxFrameBytes();

  @override
  int bind(Uint8List secret) {
    final memory = calloc<ffi.Uint8>(secret.length);
    try {
      memory.asTypedList(secret.length).setAll(0, secret);
      final pointer = _bind(memory, secret.length);
      if (pointer == ffi.nullptr) {
        throw const P2pNativeException(9, 'native endpoint bind failed');
      }
      return pointer.address;
    } finally {
      calloc.free(memory);
    }
  }

  @override
  String endpointId(int handle) {
    final pointer = ffi.Pointer<ffi.Void>.fromAddress(handle);
    final length = _idLength(pointer);
    final memory = calloc<ffi.Uint8>(length);
    try {
      _check(_idCopy(pointer, memory, length));
      return utf8.decode(memory.asTypedList(length));
    } finally {
      calloc.free(memory);
    }
  }

  @override
  String endpointTicket(int handle) {
    final memory = calloc<ffi.Uint8>(8192);
    try {
      final length = _ticket(
        ffi.Pointer<ffi.Void>.fromAddress(handle),
        memory,
        8192,
      );
      _checkLength(length);
      return utf8.decode(memory.asTypedList(length));
    } finally {
      calloc.free(memory);
    }
  }

  @override
  int connect(int handle, String ticket) {
    final bytes = Uint8List.fromList(utf8.encode(ticket));
    final memory = _allocate(bytes);
    try {
      final result = _connect(
        ffi.Pointer<ffi.Void>.fromAddress(handle),
        memory,
        bytes.length,
      );
      _checkLength(result);
      return result;
    } finally {
      calloc.free(memory);
    }
  }

  @override
  int? accept(int handle, Duration timeout) {
    final result = _accept(
      ffi.Pointer<ffi.Void>.fromAddress(handle),
      timeout.inMilliseconds,
    );
    if (result == 0) return null;
    _checkLength(result);
    return result;
  }

  @override
  Uint8List request(int handle, int connectionId, Uint8List frame) =>
      _requestBytes(handle, connectionId, frame, _request);

  @override
  Uint8List receiveRequest(int handle, int connectionId) => _receiveBytes(
    handle,
    connectionId,
    _receiveRequest,
  );

  @override
  void respond(int handle, int connectionId, Uint8List frame) {
    final memory = _allocate(frame);
    try {
      _check(
        _respond(
          ffi.Pointer<ffi.Void>.fromAddress(handle),
          connectionId,
          memory,
          frame.length,
        ),
      );
    } finally {
      calloc.free(memory);
    }
  }

  @override
  void close(int handle) => _close(ffi.Pointer<ffi.Void>.fromAddress(handle));

  Uint8List _requestBytes(
    int handle,
    int connectionId,
    Uint8List frame,
    _RequestDart operation,
  ) {
    final input = _allocate(frame);
    final output = calloc<ffi.Uint8>(maxFrameBytes);
    try {
      final length = operation(
        ffi.Pointer<ffi.Void>.fromAddress(handle),
        connectionId,
        input,
        frame.length,
        output,
        maxFrameBytes,
      );
      _checkLength(length);
      return Uint8List.fromList(output.asTypedList(length));
    } finally {
      calloc.free(input);
      calloc.free(output);
    }
  }

  Uint8List _receiveBytes(
    int handle,
    int connectionId,
    _ReceiveRequestDart operation,
  ) {
    final output = calloc<ffi.Uint8>(maxFrameBytes);
    try {
      final length = operation(
        ffi.Pointer<ffi.Void>.fromAddress(handle),
        connectionId,
        output,
        maxFrameBytes,
      );
      _checkLength(length);
      return Uint8List.fromList(output.asTypedList(length));
    } finally {
      calloc.free(output);
    }
  }

  static ffi.Pointer<ffi.Uint8> _allocate(Uint8List bytes) {
    final memory = calloc<ffi.Uint8>(bytes.length);
    memory.asTypedList(bytes.length).setAll(0, bytes);
    return memory;
  }

  static void _check(int code) {
    if (code != 0) throw P2pNativeException(code, 'native P2P operation failed');
  }

  static void _checkLength(int result) {
    if (result < 0) {
      final code = -result;
      throw P2pNativeException(code, 'native P2P operation failed');
    }
  }

  static ffi.DynamicLibrary _openDefaultLibrary() {
    if (Platform.isWindows) return ffi.DynamicLibrary.open('easycalendar_p2p.dll');
    if (Platform.isAndroid || Platform.isLinux) {
      return ffi.DynamicLibrary.open('libeasycalendar_p2p.so');
    }
    if (Platform.isMacOS) return ffi.DynamicLibrary.open('libeasycalendar_p2p.dylib');
    return ffi.DynamicLibrary.process();
  }
}

typedef _VersionNative = ffi.Uint32 Function();
typedef _VersionDart = int Function();
typedef _BindNative = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.UintPtr,
);
typedef _BindDart = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _IdLengthNative = ffi.UintPtr Function(ffi.Pointer<ffi.Void>);
typedef _IdLengthDart = int Function(ffi.Pointer<ffi.Void>);
typedef _IdCopyNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint8>,
  ffi.UintPtr,
);
typedef _IdCopyDart = int Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _TicketNative = ffi.Int64 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint8>,
  ffi.UintPtr,
);
typedef _TicketDart = int Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _ConnectNative = ffi.Int64 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint8>,
  ffi.UintPtr,
);
typedef _ConnectDart = int Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _AcceptNative = ffi.Int64 Function(ffi.Pointer<ffi.Void>, ffi.Uint64);
typedef _AcceptDart = int Function(ffi.Pointer<ffi.Void>, int);
typedef _RequestNative = ffi.Int64 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Uint64,
  ffi.Pointer<ffi.Uint8>,
  ffi.UintPtr,
  ffi.Pointer<ffi.Uint8>,
  ffi.UintPtr,
);
typedef _RequestDart = int Function(
  ffi.Pointer<ffi.Void>,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _ReceiveRequestNative = ffi.Int64 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Uint64,
  ffi.Pointer<ffi.Uint8>,
  ffi.UintPtr,
);
typedef _ReceiveRequestDart = int Function(
  ffi.Pointer<ffi.Void>,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _RespondNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Uint64,
  ffi.Pointer<ffi.Uint8>,
  ffi.UintPtr,
);
typedef _RespondDart = int Function(
  ffi.Pointer<ffi.Void>,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
);
typedef _CloseNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _CloseDart = void Function(ffi.Pointer<ffi.Void>);
