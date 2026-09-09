import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

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

  Future<void> respond({required int connectionId, required Uint8List frame});

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
    final secret = _decodeP2pSecret(encoded);
    _handle = api.bind(secret);
    if (_handle == 0) {
      _handle = null;
      throw const SyncTransportException('P2P endpoint could not be started.');
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
  Future<int?> accept({
    Duration timeout = const Duration(milliseconds: 250),
  }) async => api.accept(_requireHandle(), timeout);

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
      );
    }
    return handle;
  }
}

/// Runs synchronous FFI calls away from Flutter's UI isolate.
class IsolateP2pBridge implements P2pBridge {
  _P2pWorker? _worker;

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
    if (_worker != null) return;
    final encoded = endpointSecret?.trim() ?? '';
    if (encoded.isEmpty) {
      throw const SyncTransportException(
        'P2P endpoint private key is not configured.',
        permanent: true,
      );
    }
    final secret = _decodeP2pSecret(encoded);
    final worker = await _P2pWorker.spawn();
    _worker = worker;
    try {
      await _invoke<void>('bind', secret);
    } catch (_) {
      _worker = null;
      await worker.close();
      rethrow;
    }
  }

  @override
  Future<String> endpointId() => _invoke<String>('endpoint_id');

  @override
  Future<String> exportTicket() => _invoke<String>('endpoint_ticket');

  @override
  Future<int> connect(String ticket) => _invoke<int>('connect', ticket);

  @override
  Future<int?> accept({Duration timeout = const Duration(milliseconds: 250)}) =>
      _invoke<int?>('accept', timeout.inMilliseconds);

  @override
  Future<Uint8List> request({
    required int connectionId,
    required Uint8List frame,
  }) => _invoke<Uint8List>('request', <Object?>[connectionId, frame]);

  @override
  Future<Uint8List> receiveRequest({required int connectionId}) =>
      _invoke<Uint8List>('receive_request', connectionId);

  @override
  Future<void> respond({required int connectionId, required Uint8List frame}) =>
      _invoke<void>('respond', <Object?>[connectionId, frame]);

  @override
  Future<void> close() async {
    final worker = _worker;
    _worker = null;
    if (worker != null) await worker.close();
  }

  Future<T> _invoke<T>(String operation, [Object? argument]) async {
    final worker = _worker;
    if (worker == null) {
      throw const SyncTransportException(
        'P2P native bridge has not been started.',
      );
    }
    try {
      return await worker.call<T>(operation, argument);
    } on P2pNativeException catch (error) {
      throw _syncException(error);
    }
  }

  static SyncTransportException _syncException(P2pNativeException error) {
    final permanent = switch (error.code) {
      1 || 2 || 3 || 4 || 6 || 7 || 8 || 10 || 12 => true,
      _ => false,
    };
    return SyncTransportException(
      'P2P operation failed (${error.code}): ${error.message}',
      permanent: permanent,
    );
  }
}

Uint8List _decodeP2pSecret(String value) {
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

class _P2pWorker {
  _P2pWorker({
    required this.isolate,
    required this.responses,
    required this.commands,
  });

  final Isolate isolate;
  final ReceivePort responses;
  final SendPort commands;
  final _pending = <int, Completer<Object?>>{};
  StreamSubscription<Object?>? _subscription;
  int _nextRequestId = 1;
  bool _closed = false;

  static Future<_P2pWorker> spawn() async {
    final responses = ReceivePort();
    final isolate = await Isolate.spawn<Object?>(
      _p2pWorkerMain,
      responses.sendPort,
      errorsAreFatal: false,
    );
    final stream = responses.asBroadcastStream();
    final ready = await stream.first;
    if (ready is! List<Object?> ||
        ready.length != 2 ||
        ready[0] != 'ready' ||
        ready[1] is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      throw const P2pNativeException(9, 'native worker failed to start');
    }
    final worker = _P2pWorker(
      isolate: isolate,
      responses: responses,
      commands: ready[1] as SendPort,
    );
    worker._subscription = stream.listen(worker._handleMessage);
    return worker;
  }

  Future<T> call<T>(String operation, [Object? argument]) {
    if (_closed) return Future<T>.error(StateError('P2P worker is closed'));
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    commands.send(<Object?>[id, operation, argument]);
    return completer.future.then((value) => value as T);
  }

  Future<void> close() async {
    if (_closed) return;
    try {
      await call<void>('close');
    } catch (_) {}
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('P2P worker closed'));
      }
    }
    _pending.clear();
    await _subscription?.cancel();
    responses.close();
    isolate.kill(priority: Isolate.immediate);
  }

  void _handleMessage(Object? message) {
    if (message is! List<Object?> || message.length < 3) return;
    final id = message[0];
    if (id is! int || id == 0) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (message[1] == true) {
      completer.complete(message[2]);
    } else {
      completer.completeError(
        P2pNativeException(message[2] as int, message[3] as String),
      );
    }
  }
}

void _p2pWorkerMain(Object? message) {
  final response = message as SendPort;
  final commands = ReceivePort();
  response.send(<Object?>['ready', commands.sendPort]);
  final api = FfiP2pNativeApi.tryLoad();
  int? handle;
  Future<void> handleCommand(Object? message) async {
    if (message is! List<Object?> || message.length < 3) return;
    final id = message[0];
    final operation = message[1];
    if (id is! int || operation is! String) return;
    try {
      if (operation == 'close') {
        if (api != null && handle != null) api.close(handle!);
        handle = null;
        response.send(<Object?>[id, true, null]);
        return;
      }
      if (api == null) {
        throw const P2pNativeException(
          9,
          'native P2P bridge is not available on this build',
        );
      }
      final argument = message[2];
      if (operation == 'bind') {
        handle = api.bind(argument as Uint8List);
        response.send(<Object?>[id, true, handle]);
        return;
      }
      final operationResult = _runP2pNativeOperation(
        api,
        _workerHandle(handle),
        operation,
        argument,
      );
      if (operationResult[0] != true) {
        throw P2pNativeException(
          operationResult[1] as int,
          operationResult[2] as String,
        );
      }
      final result = operationResult[1];
      response.send(<Object?>[id, true, result]);
    } on P2pNativeException catch (error) {
      response.send(<Object?>[id, false, error.code, error.message]);
    } catch (error) {
      response.send(<Object?>[id, false, 9, '$error']);
    }
  }

  unawaited(_consumeP2pCommands(commands, handleCommand));
}

Future<void> _consumeP2pCommands(
  ReceivePort commands,
  Future<void> Function(Object?) handleCommand,
) async {
  await for (final message in commands) {
    await handleCommand(message);
  }
}

int _workerHandle(int? handle) =>
    handle ?? (throw const P2pNativeException(11, 'P2P endpoint is closed'));

List<Object?> _runP2pNativeOperation(
  FfiP2pNativeApi api,
  int handle,
  String operation,
  Object? argument,
) {
  try {
    final pair = argument is List<Object?> ? argument : const <Object?>[];
    final result = switch (operation) {
      'endpoint_id' => api.endpointId(handle),
      'endpoint_ticket' => api.endpointTicket(handle),
      'connect' => api.connect(handle, argument as String),
      'accept' => api.accept(handle, Duration(milliseconds: argument as int)),
      'request' => api.request(handle, pair[0] as int, pair[1] as Uint8List),
      'receive_request' => api.receiveRequest(handle, argument as int),
      'respond' => _respondWorker(
        api,
        handle,
        pair[0] as int,
        pair[1] as Uint8List,
      ),
      _ => throw const P2pNativeException(10, 'unknown native P2P operation'),
    };
    return <Object?>[true, result];
  } on P2pNativeException catch (error) {
    final message = error.code == 9
        ? (api.lastError(handle) ?? error.message)
        : error.message;
    return <Object?>[false, error.code, message];
  } catch (error) {
    return <Object?>[false, 9, '$error'];
  }
}

Object? _respondWorker(
  P2pNativeApi api,
  int handle,
  int connectionId,
  Uint8List frame,
) {
  api.respond(handle, connectionId, frame);
  return null;
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
  }) => _unavailable();

  @override
  Future<Uint8List> receiveRequest({required int connectionId}) =>
      _unavailable();

  @override
  Future<void> respond({required int connectionId, required Uint8List frame}) =>
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
      _lastErrorLength = library
          .lookupFunction<_IdLengthNative, _IdLengthDart>(
            'easycalendar_p2p_endpoint_last_error_len',
          ),
      _lastErrorCopy = library
          .lookupFunction<_IdCopyNative, _IdCopyDart>(
            'easycalendar_p2p_endpoint_last_error_copy',
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
      _receiveRequest = library
          .lookupFunction<_ReceiveRequestNative, _ReceiveRequestDart>(
            'easycalendar_p2p_endpoint_receive_request',
          ),
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
  final _IdLengthDart _lastErrorLength;
  final _IdCopyDart _lastErrorCopy;
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

  String? lastError(int handle) {
    final pointer = ffi.Pointer<ffi.Void>.fromAddress(handle);
    final length = _lastErrorLength(pointer);
    if (length == 0) return null;
    final memory = calloc<ffi.Uint8>(length);
    try {
      _check(_lastErrorCopy(pointer, memory, length));
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
  Uint8List receiveRequest(int handle, int connectionId) =>
      _receiveBytes(handle, connectionId, _receiveRequest);

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
    if (code != 0) throw P2pNativeException(code, _nativeErrorMessage(code));
  }

  static void _checkLength(int result) {
    if (result < 0) {
      final code = -result;
      throw P2pNativeException(code, _nativeErrorMessage(code));
    }
  }

  static String _nativeErrorMessage(int code) => switch (code) {
    1 => 'invalid P2P frame code',
    2 => 'unsupported P2P protocol',
    3 => 'P2P authentication failed',
    4 => 'P2P member revoked',
    5 => 'primary endpoint unavailable',
    6 => 'P2P frame is too large',
    7 => 'invalid sync change',
    8 => 'invalid sync cursor',
    9 => 'P2P transport unavailable; the relay or network may be unreachable',
    10 => 'invalid P2P argument',
    11 => 'P2P endpoint is closed',
    12 => 'P2P output buffer is too small',
    _ => 'native P2P operation failed',
  };

  static ffi.DynamicLibrary _openDefaultLibrary() {
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('easycalendar_p2p.dll');
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return ffi.DynamicLibrary.open('libeasycalendar_p2p.so');
    }
    if (Platform.isMacOS) {
      final executable = File(Platform.resolvedExecutable);
      final bundleLibrary = path.join(
        executable.parent.parent.path,
        'Frameworks',
        'libeasycalendar_p2p.dylib',
      );
      try {
        return ffi.DynamicLibrary.open(bundleLibrary);
      } on Object {
        return ffi.DynamicLibrary.open('libeasycalendar_p2p.dylib');
      }
    }
    return ffi.DynamicLibrary.process();
  }
}

typedef _VersionNative = ffi.Uint32 Function();
typedef _VersionDart = int Function();
typedef _BindNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, ffi.UintPtr);
typedef _BindDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>, int);
typedef _IdLengthNative = ffi.UintPtr Function(ffi.Pointer<ffi.Void>);
typedef _IdLengthDart = int Function(ffi.Pointer<ffi.Void>);
typedef _IdCopyNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.UintPtr,
    );
typedef _IdCopyDart =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef _TicketNative =
    ffi.Int64 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.UintPtr,
    );
typedef _TicketDart =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef _ConnectNative =
    ffi.Int64 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Uint8>,
      ffi.UintPtr,
    );
typedef _ConnectDart =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);
typedef _AcceptNative = ffi.Int64 Function(ffi.Pointer<ffi.Void>, ffi.Uint64);
typedef _AcceptDart = int Function(ffi.Pointer<ffi.Void>, int);
typedef _RequestNative =
    ffi.Int64 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Uint64,
      ffi.Pointer<ffi.Uint8>,
      ffi.UintPtr,
      ffi.Pointer<ffi.Uint8>,
      ffi.UintPtr,
    );
typedef _RequestDart =
    int Function(
      ffi.Pointer<ffi.Void>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
    );
typedef _ReceiveRequestNative =
    ffi.Int64 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Uint64,
      ffi.Pointer<ffi.Uint8>,
      ffi.UintPtr,
    );
typedef _ReceiveRequestDart =
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Uint8>, int);
typedef _RespondNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Uint64,
      ffi.Pointer<ffi.Uint8>,
      ffi.UintPtr,
    );
typedef _RespondDart =
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Uint8>, int);
typedef _CloseNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _CloseDart = void Function(ffi.Pointer<ffi.Void>);
