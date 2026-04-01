import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:get/get.dart';

import 'main.dart';

class NativeWhatsShare {
  static const _channel = MethodChannel('com.solexpresspy.email_processor/whshare');

  /// Comparte múltiples PDFs por Intent nativo (solo archivos, sin texto).
  /// [files] = lista de Files originales (se copiarán a caché compartible).
  /// [phone] = número internacional sin '+' (opcional si no usas 'jid').
  static Future<void> shareMultiplePdfsNative({
    required List<File> files,
    String? phone,
    bool forceBusiness = false,
    bool useJid = true,
  }) async {
    // Copia previa a caché compartible
    final externalCaches = await getExternalCacheDirectories();
    final cacheDir = (externalCaches != null && externalCaches.isNotEmpty)
        ? externalCaches.first
        : await getTemporaryDirectory();
    final shareDir = Directory('${cacheDir.path}/wh_share_native_multi');
    if (!await shareDir.exists()) {
      await shareDir.create(recursive: true);
    }

    final tempPaths = <String>[];
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      final tmp = File('${shareDir.path}/$name');
      // sobrescribe por simplicidad; si quieres, agrega sufijo único
      await tmp.writeAsBytes(await f.readAsBytes(), flush: true);
      tempPaths.add(tmp.path);
    }

    // Llamada nativa
    await _channel.invokeMethod('sharePdfToWhatsApp', <String, dynamic>{
      'paths': tempPaths,                            // <<< lista
      'mime': 'application/pdf',
      'phone': (phone ?? '').replaceAll(RegExp(r'\D'), ''),
      'useBusiness': forceBusiness,
      'useJid': useJid,
    });
  }
}
