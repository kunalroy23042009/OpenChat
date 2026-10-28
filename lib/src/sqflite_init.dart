// sqflite_init.dart - Platform-specific sqflite initialization

export 'sqflite_init_stub.dart' if (dart.library.js_interop) 'sqflite_init_web.dart';
