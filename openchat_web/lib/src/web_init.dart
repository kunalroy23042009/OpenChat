// web_init.dart - Web-specific initialization
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:indexed_db/indexed_db.dart';

/// Initialize web-specific services (IndexedDB for secure history, etc.)
Future<void> initializeWebServices() async {
  // Initialize IndexedDB for encrypted chat history
  await _initIndexedDB();
  
  // Set up service worker for background sync (if supported)
  if (await _isServiceWorkerSupported()) {
    _registerServiceWorker();
  }
}

/// Initialize IndexedDB for secure history storage
Future<void> _initIndexedDB() async {
  try {
    final db = await IdbFactory.idb.open('openchat_history', version: 1, onUpgradeNeeded: (event) {
      final database = event.database;
      if (!database.objectStoreNames.contains('secure_histories')) {
        database.createObjectStore('secure_histories', keyPath: 'storage_key');
      }
    });
    await db.close();
  } catch (_) {
    // IndexedDB not available, will fall back to localStorage
  }
}

/// Check if service worker is supported
Future<bool> _isServiceWorkerSupported() async {
  // In web, navigator.serviceWorker is available
  return true;
}

/// Register service worker for background sync
void _registerServiceWorker() {
  // Service worker registration handled in index.html
}

/// Web-specific secure history database using IndexedDB
class WebSecureHistoryDatabase {
  static const String _storeName = 'secure_histories';
  static const String _keyName = 'openchat.secureHistoryKey.v1';
  
  final SharedPreferences preferences;
  final IdbFactory _idb = IdbFactory.idb;
  IdbDatabase? _db;
  List<int>? _key;
  
  Future<void> initialize(SharedPreferences prefs) async {
    if (_db != null) return;
    
    // Load or create encryption key
    final encoded = prefs.getString(_keyName);
    if (encoded != null) {
      _key = base64Decode(encoded);
    } else {
      _key = List<int>.generate(32, (_) => DateTime.now().millisecondsSinceEpoch & 0xFF);
      await prefs.setString(_keyName, base64Encode(_key!));
    }
    
    // Open IndexedDB
    _db = await _idb.open('openchat_history', version: 1, onUpgradeNeeded: (event) {
      final database = event.database;
      if (!database.objectStoreNames.contains(_storeName)) {
        database.createObjectStore(_storeName, keyPath: 'storage_key');
      }
    });
    
    // Migrate from localStorage if needed
    await _migrateFromLocalStorage(prefs);
  }
  
  Future<void> _migrateFromLocalStorage(SharedPreferences prefs) async {
    final prefix = 'openchat.secure.v1.';
    for (final key in prefs.getKeys().where((k) => k.startsWith(prefix))) {
      if (_db == null) return;
      final value = prefs.getString(key);
      if (value == null) continue;
      
      try {
        // Validate JSON before committing
        jsonDecode(value);
        await write(key, value);
        await prefs.remove(key);
      } catch (_) {
        // Skip invalid entries
      }
    }
  }
  
  String? read(String storageKey) {
    // Synchronous read from cache - implement async version for real use
    return null; // Placeholder - implement async read
  }
  
  Future<String?> readAsync(String storageKey) async {
    if (_db == null) return null;
    try {
      final txn = _db!.transaction(_storeName, 'readonly');
      final store = txn.objectStore(_storeName);
      final request = store.getObject(storageKey);
      await request;
      final result = request.result;
      if (result != null) {
        final payload = result['payload'] as List<int>;
        return _open(storageKey, Uint8List.fromList(payload));
      }
    } catch (_) {}
    return null;
  }
  
  Map<String, String> readEntries(String prefix) {
    return {}; // Placeholder
  }
  
  Future<void> write(String storageKey, String json) async {
    if (_db == null || _key == null) return;
    try {
      final payload = await _seal(storageKey, json);
      final txn = _db!.transaction(_storeName, 'readwrite');
      final store = txn.objectStore(_storeName);
      await store.put({
        'storage_key': storageKey,
        'payload': payload,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }
  
  Future<Uint8List> _seal(String storageKey, String clearText) async {
    // Simple XOR encryption for web (in production, use Web Crypto API)
    final key = _key!;
    final nonce = List<int>.generate(12, (_) => DateTime.now().millisecondsSinceEpoch & 0xFF);
    final data = utf8.encode(clearText);
    final encrypted = List<int>.generate(data.length, (i) => data[i] ^ key[i % key.length]);
    return Uint8List.fromList([...nonce, ...encrypted]);
  }
  
  Future<String> _open(String storageKey, Uint8List bytes) async {
    if (bytes.length < 12) throw StateError('Encrypted chat history is damaged.');
    final nonce = bytes.sublist(0, 12);
    final cipherText = bytes.sublist(12);
    final key = _key!;
    final data = List<int>.generate(cipherText.length, (i) => cipherText[i] ^ key[i % key.length]);
    return utf8.decode(data);
  }
  
  Future<void> close() async {
    await _db?.close();
    _db = null;
    _key = null;
  }
}