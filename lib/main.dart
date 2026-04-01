import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart'; // firstWhereOrNull
import 'package:email_processor/share_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // PlatformException
import 'package:get/get.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/gmail/v1.dart' as gapi;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart'; // ← share_plus
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// ======================== Constantes / Prefs ========================
const kPrefsRules = 'prefs_rules';
const kPrefsDays  = 'prefs_recent_days';
const kPrefsWhats = 'prefs_whatsapp_phone';

const kDefaultDays = 90;
const kDefaultWhats = '595993288289'; // sin '+'

const kBgTaskName = 'gmail_sync_task';
final FlutterLocalNotificationsPlugin notif = FlutterLocalNotificationsPlugin();

/// ======================== Util HTTP OAuth ===========================
class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();
  GoogleAuthClient(this._headers);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

/// ======================== Modelos ===========================
class SubjectRule {
  final String keyword;
  final String relativeDir;
  SubjectRule({required this.keyword, required this.relativeDir});

  Map<String, dynamic> toJson() => {'keyword': keyword, 'relativeDir': relativeDir};
  factory SubjectRule.fromJson(Map<String, dynamic> j) =>
      SubjectRule(keyword: j['keyword'], relativeDir: j['relativeDir']);

  String get key => '$keyword||$relativeDir';
}

class AttachmentEntry {
  final String path;
  final int size;
  final int savedAt;
  AttachmentEntry({required this.path, required this.size, required this.savedAt});
  Map<String, dynamic> toJson() => {'path': path, 'size': size, 'savedAt': savedAt};
  factory AttachmentEntry.fromJson(Map<String, dynamic> j) =>
      AttachmentEntry(path: j['path'], size: j['size'] ?? 0, savedAt: j['savedAt'] ?? 0);
}

class SyncIndex {
  final Map<String, AttachmentEntry> attachments; // key: messageId_attachmentId
  final Map<String, RuleSyncState> rules;         // (opcional futuro) estados por regla
  SyncIndex({required this.attachments, Map<String, RuleSyncState>? rules}) : rules = rules ?? {};

  Map<String, dynamic> toJson() => {
    'attachments': attachments.map((k, v) => MapEntry(k, v.toJson())),
    'rules': rules.map((k, v) => MapEntry(k, v.toJson())),
  };

  factory SyncIndex.fromJson(Map<String, dynamic> j) => SyncIndex(
    attachments: (j['attachments'] as Map? ?? {}).map(
          (k, v) => MapEntry(k as String, AttachmentEntry.fromJson((v as Map).cast())),
    ),
    rules: (j['rules'] as Map? ?? {}).map(
          (k, v) => MapEntry(k as String, RuleSyncState.fromJson((v as Map).cast())),
    ),
  );
}

class RuleSyncState {
  String? lastHistoryId;
  int? lastInternalDate;
  RuleSyncState({this.lastHistoryId, this.lastInternalDate});
  Map<String, dynamic> toJson() => {
    if (lastHistoryId != null) 'lastHistoryId': lastHistoryId,
    if (lastInternalDate != null) 'lastInternalDate': lastInternalDate,
  };
  factory RuleSyncState.fromJson(Map<String, dynamic> j) =>
      RuleSyncState(lastHistoryId: j['lastHistoryId'], lastInternalDate: j['lastInternalDate']);
}

class _AttachmentRef {
  final String attachmentId;
  final String filename;
  final String messageId;
  _AttachmentRef({required this.attachmentId, required this.filename, required this.messageId});
}

/// ======================== Controladores ===========================
class LogController extends GetxController {
  final log = ''.obs;
  void add(String msg) {
    final t = DateTime.now().toIso8601String();
    log.value = '$t  $msg\n${log.value}';
  }
}

class SettingsController extends GetxController {
  final rules = <SubjectRule>[
    SubjectRule(keyword: 'SNC',            relativeDir: 'download/snc'),
    SubjectRule(keyword: 'ORDEN DE PAGO',  relativeDir: 'download/orden_de_pago'),
  ].obs;

  final recentDays = kDefaultDays.obs;
  final whatsPhone = kDefaultWhats.obs; // sin '+'

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(kPrefsRules);
    if (list != null) {
      rules.assignAll(list.map((s) => SubjectRule.fromJson(jsonDecode(s))));
    }
    recentDays.value = p.getInt(kPrefsDays) ?? kDefaultDays;
    whatsPhone.value = p.getString(kPrefsWhats) ?? kDefaultWhats;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(kPrefsRules, rules.map((r) => jsonEncode(r.toJson())).toList());
    await p.setInt(kPrefsDays, recentDays.value);
    await p.setString(kPrefsWhats, whatsPhone.value);
  }
}

class GmailService extends GetxService {
  final Rxn<GoogleSignInAccount> userRx = Rxn<GoogleSignInAccount>();
  gapi.GmailApi? api;

  GoogleSignIn get _gs => GoogleSignIn(scopes: ['email', gapi.GmailApi.gmailReadonlyScope]);

  Future<GmailService> init() async => this;

  Future<void> trySilentSignIn() async {
    final logger = Get.find<LogController>();
    try {
      final acc = await _gs.signInSilently();
      if (acc != null) {
        final headers = await acc.authHeaders;
        api = gapi.GmailApi(GoogleAuthClient(headers));
        userRx.value = acc;
        logger.add('Silent sign-in OK: ${acc.email}');
      } else {
        userRx.value = null;
        api = null;
        logger.add('Silent sign-in: sin sesión previa.');
      }
    } on PlatformException catch (e) {
      userRx.value = null; api = null;
      logger.add('Silent sign-in PlatformException: ${e.code} | ${e.message}');
    } catch (e) {
      userRx.value = null; api = null;
      logger.add('Silent sign-in error: $e');
    }
  }

  Future<void> interactiveSignIn() async {
    final logger = Get.find<LogController>();
    try {
      final acc = await _gs.signIn(); // abre account picker
      if (acc == null) {
        logger.add('Sign-in cancelado por el usuario.');
        return;
      }
      final headers = await acc.authHeaders;
      api = gapi.GmailApi(GoogleAuthClient(headers));
      userRx.value = acc;
      logger.add('Interactive sign-in OK: ${acc.email}');
    } on PlatformException catch (e) {
      userRx.value = null; api = null;
      logger.add('Interactive PlatformException: ${e.code} | ${e.message}');
      rethrow;
    } catch (e) {
      userRx.value = null; api = null;
      logger.add('Interactive sign-in error: $e');
      rethrow;
    }
  }

  Future<void> signOut() async {
    try { await _gs.signOut(); } catch (_) {}
    userRx.value = null;
    api = null;
    Get.find<LogController>().add('Sesión cerrada.');
  }
}

class SyncController extends GetxController {
  final GmailService gmail = Get.find();
  final SettingsController settings = Get.find();
  final LogController logger = Get.find();

  Directory? _baseDir;
  Future<Directory> _getBaseDir() async {
    if (_baseDir != null) return _baseDir!;
    // /Android/data/<package>/files → no requiere permisos en runtime
    final d = await getExternalStorageDirectory();
    _baseDir = d ?? await getApplicationDocumentsDirectory();
    return _baseDir!;
  }

  String _indexPath(Directory root) => '${root.path}/.gmail_pdf_sync_index.json';

  Future<SyncIndex> _loadIndex(Directory root) async {
    final f = File(_indexPath(root));
    if (!await f.exists()) return SyncIndex(attachments: {});
    try {
      final data = jsonDecode(await f.readAsString());
      return SyncIndex.fromJson((data as Map).cast());
    } catch (_) {
      return SyncIndex(attachments: {});
    }
  }

  Future<void> _saveIndex(Directory root, SyncIndex idx) async {
    final f = File(_indexPath(root));
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(idx.toJson()), flush: true);
  }

  Future<void> _probeWrite(Directory root) async {
    final probe = File('${root.path}/.write_probe.txt');
    try {
      await probe.writeAsString('ok ${DateTime.now()}', flush: true);
      logger.add('Escritura OK en: ${root.path}');
    } catch (e) {
      logger.add('Fallo al escribir en ${root.path}: $e');
    }
  }

  // No pedimos permisos: app-specific no los requiere
  Future<bool> _ensureStoragePerms() async => true;

  String _attKey(String messageId, String attachmentId) => '${messageId}_$attachmentId';

  String _sanitizeFileName(String name) {
    final replaced = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return replaced.isEmpty ? 'documento.pdf' : replaced;
  }

  Future<void> syncNow() async {
    if (gmail.api == null) {
      logger.add('No hay sesión Gmail. Inicia sesión primero.');
      return;
    }
    if (!await _ensureStoragePerms()) {
      logger.add('Permisos de almacenamiento no concedidos (no deberían requerirse).');
      return;
    }

    final api = gmail.api!;
    final root = await _getBaseDir();
    await _probeWrite(root);
    final idx = await _loadIndex(root);

    logger.add('Sincronizando… raíz: ${root.path}');
    for (final rule in settings.rules) {
      final destDir = Directory('${root.path}/${rule.relativeDir}');
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
        logger.add('Carpeta creada: ${destDir.path}');
      }

      // Consulta base: asunto + adjunto PDF + últimos N días
      final q = 'subject:"${rule.keyword}" has:attachment filename:pdf newer_than:${settings.recentDays.value}d';
      logger.add('Regla "${rule.keyword}": $q');
      String? pageToken;
      int totalMatches = 0, totalSaved = 0;

      do {
        final list = await api.users.messages.list('me', q: q, maxResults: 50, pageToken: pageToken);
        pageToken = list.nextPageToken;
        final msgs = list.messages ?? const <gapi.Message>[];
        totalMatches += msgs.length;

        for (final m in msgs) {
          final id = m.id;
          if (id == null) continue;

          final full = await api.users.messages.get('me', id, format: 'full');

          // Extraer adjuntos PDF
          final attachments = <_AttachmentRef>[];
          void walk(gapi.MessagePart? part) {
            if (part == null) return;
            final mime = (part.mimeType ?? '').toLowerCase();
            final filename = part.filename ?? '';
            final body = part.body;
            if ((filename.endsWith('.pdf') || mime == 'application/pdf') && body?.attachmentId != null) {
              attachments.add(_AttachmentRef(
                attachmentId: body!.attachmentId!,
                filename: filename.isNotEmpty ? filename : 'documento.pdf',
                messageId: full.id!,
              ));
            }
            for (final p in part.parts ?? const <gapi.MessagePart>[]) {
              walk(p);
            }
          }
          walk(full.payload);

          for (final a in attachments) {
            final key = _attKey(a.messageId, a.attachmentId);
            final prev = idx.attachments[key];
            if (prev != null && await File(prev.path).exists()) {
              logger.add('  Duplicado omitido: ${prev.path}');
              continue;
            }

            final dataResp = await api.users.messages.attachments.get('me', a.messageId, a.attachmentId);
            final data64 = dataResp.data;
            if (data64 == null) continue;

            final bytes = base64Url.decode(data64);
            final safeName = _sanitizeFileName(a.filename);
            final out = File('${destDir.path}/$safeName');
            await out.writeAsBytes(bytes, flush: true);

            idx.attachments[key] = AttachmentEntry(
              path: out.path, size: bytes.lengthInBytes, savedAt: DateTime.now().millisecondsSinceEpoch,
            );
            totalSaved++;
            logger.add('  Guardado: ${out.path} (${bytes.lengthInBytes} bytes)');
          }
        }
      } while (pageToken != null);

      await _saveIndex(root, idx);
      logger.add('Regla "${rule.keyword}" → mensajes: $totalMatches, nuevos guardados: $totalSaved');
    }

    logger.add('Sincronización finalizada.');
  }

  // ---------- Archivos / UI helpers ----------
  Future<List<FileSystemEntity>> listPdfsForRule(SubjectRule rule, {int? onlyLastDays}) async {
    final root = await _getBaseDir();
    final dir = Directory('${root.path}/${rule.relativeDir}');
    if (!await dir.exists()) return const [];
    final all = await dir.list().toList();
    final pdfs = all.where((e) => e.path.toLowerCase().endsWith('.pdf')).toList();

    if (onlyLastDays != null && onlyLastDays > 0) {
      final since = DateTime.now().subtract(Duration(days: onlyLastDays));
      return pdfs.where((e) {
        final f = File(e.path);
        final stat = f.statSync();
        return stat.modified.isAfter(since);
      }).toList();
    }
    return pdfs;
  }

  Future<void> openFile(File f) => OpenFilex.open(f.path);

  Future<File> _safeMove(File src, File dst) async {
    File target = dst;
    if (await target.exists()) {
      final name = target.uri.pathSegments.last;
      final dir = target.parent.path;
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;
      final ext  = dot > 0 ? name.substring(dot) : '';
      final ts   = DateTime.now().millisecondsSinceEpoch;
      target = File('$dir/${base}_$ts$ext');
    }
    try {
      return await src.rename(target.path);
    } catch (_) {
      await src.copy(target.path);
      await src.delete();
      return File(target.path);
    }
  }

  /// Copia el PDF a caché compartible y lo comparte con share_plus;
  /// después mueve el ORIGINAL a OLD/
  Future<void> shareToWhatsAndArchive(File file, SubjectRule rule) async {
    try {
      final phone = settings.whatsPhone.value; // conservamos el dato por si luego agregas Intent nativo
      logger.add('Preparando share para +$phone');

      // 1) Copiar a caché externa (compartible por otras apps)
      final externalCaches = await getExternalCacheDirectories();
      final cacheDir = (externalCaches != null && externalCaches.isNotEmpty)
          ? externalCaches.first
          : await getTemporaryDirectory(); // fallback
      final shareDir = Directory('${cacheDir.path}/wh_share');
      if (!await shareDir.exists()) {
        await shareDir.create(recursive: true);
      }

      final name = file.uri.pathSegments.last;
      final tempShare = File('${shareDir.path}/$name');
      await tempShare.writeAsBytes(await file.readAsBytes(), flush: true);

      // 2) Compartir con share_plus (no se pasa 'text' para documentos)
      logger.add('Abriendo hoja de compartir con: ${tempShare.path}');
      final xfile = XFile(
        tempShare.path,
        mimeType: 'application/pdf',
        name: name,
      );

      // sharePositionOrigin opcional: útil en tablets/desktop
      await Share.shareXFiles([xfile],
          subject: null,
          text: null,
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 100, 100));

      // 3) Mover el ORIGINAL a OLD/
      final root = await _getBaseDir();
      final oldDir = Directory('${root.path}/${rule.relativeDir}/OLD');
      if (!await oldDir.exists()) await oldDir.create(recursive: true);
      final target = File('${oldDir.path}/${file.uri.pathSegments.last}');
      final archived = await _safeMove(file, target);
      logger.add('Archivado: ${archived.path}');
    } catch (e) {
      logger.add('Error compartir/archivar: $e');
    }
  }
}

/// ======================== Workmanager (placeholder) =================
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    const android = AndroidNotificationDetails('sync_channel', 'Sincronización');
    const details = NotificationDetails(android: android);
    await notif.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'Sincronización',
      'Tarea de fondo ejecutada.',
      details,
    );
    return Future.value(true);
  });
}

/// ======================== Bootstrap / DI ============================
Future<void> _initInfra() async {
  WidgetsFlutterBinding.ensureInitialized();

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await notif.initialize(const InitializationSettings(android: androidInit));
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

  Get.put(LogController());
  Get.put(SettingsController());
  await Get.find<SettingsController>().load();
  await Get.putAsync<GmailService>(() async => GmailService().init());
  Get.put(SyncController());

  // Intento silencioso de sesión al arrancar
  await Get.find<GmailService>().trySilentSignIn();
}

Future<void> main() async {
  await _initInfra();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// ======================== UI ============================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  void _showAddRuleDialog() {
    final keyCtl = TextEditingController();
    final dirCtl = TextEditingController(text: 'download/');
    final settings = Get.find<SettingsController>();
    Get.dialog(AlertDialog(
      title: const Text('Agregar nueva regla'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(decoration: const InputDecoration(labelText: 'Palabra clave del asunto'), controller: keyCtl),
          const SizedBox(height: 8),
          TextField(decoration: const InputDecoration(labelText: 'Carpeta de destino (p. ej.: download/snc)'), controller: dirCtl),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Get.back(), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () async {
            if (keyCtl.text.trim().isNotEmpty && dirCtl.text.trim().isNotEmpty) {
              settings.rules.add(SubjectRule(keyword: keyCtl.text.trim(), relativeDir: dirCtl.text.trim()));
              await settings.save();
              Get.back();
            }
          },
          child: const Text('Aceptar'),
        ),
      ],
    ));
  }

  Future<void> _handleInteractiveSignIn(BuildContext context) async {
    try {
      await Get.find<GmailService>().interactiveSignIn();
    } on PlatformException catch (e) {
      String hint = '';
      switch (e.code) {
        case 'play_services_not_available':
        case 'network_error':
          hint = 'Actualiza Google Play Services y verifica la conexión. En emuladores usa imagen con "Google Play".';
          break;
        case 'sign_in_canceled':
          hint = 'La selección de cuenta fue cancelada.';
          break;
        default:
          hint = 'Revisa OAuth Android (packageName, SHA-1) y que Gmail API esté habilitada.';
      }
      // ignore: use_build_context_synchronously
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('No se pudo iniciar sesión'),
          content: Text('${e.message ?? e.code}\n\n$hint'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
        ),
      );
    } catch (e) {
      // ignore: use_build_context_synchronously
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Error inesperado'),
          content: Text('$e'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar'))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final gmail = Get.find<GmailService>();
    final settings = Get.find<SettingsController>();
    final sync = Get.find<SyncController>();
    final logger = Get.find<LogController>();

    return Scaffold(
      appBar: AppBar(
        title: Obx(() => Text(gmail.userRx.value?.email ?? 'Sin sesión')),
        actions: [
          IconButton(
            tooltip: 'Reintentar silencioso',
            icon: const Icon(Icons.refresh),
            onPressed: () async => gmail.trySilentSignIn(),
          ),
          IconButton(
            tooltip: 'Elegir cuenta',
            icon: const Icon(Icons.account_circle),
            onPressed: () => _handleInteractiveSignIn(context),
          ),
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () async => gmail.signOut(),
          ),
        ],
      ),
      body: Obx(() {
        final user = gmail.userRx.value;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ===== Acciones principales =====
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: user == null ? null : () async => sync.syncNow(),
                        icon: const Icon(Icons.download),
                        label: const Text('Sincronizar PDFs'),
                      ),
                      FilledButton.icon(
                        onPressed: () => _handleInteractiveSignIn(context),
                        icon: const Icon(Icons.manage_accounts),
                        label: const Text('Elegir/Cambiar cuenta'),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Últimos días:'),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 90,
                            child: Obx(() => TextField(
                              keyboardType: TextInputType.number,
                              controller: TextEditingController(text: settings.recentDays.value.toString()),
                              onSubmitted: (v) async {
                                settings.recentDays.value = (int.tryParse(v) ?? kDefaultDays).clamp(1, 365);
                                await settings.save();
                              },
                            )),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('WhatsApp +'),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 170,
                            child: Obx(() => TextField(
                              controller: TextEditingController(text: settings.whatsPhone.value),
                              onSubmitted: (v) async {
                                settings.whatsPhone.value = v.replaceAll(RegExp(r'\D'), '');
                                await settings.save();
                              },
                            )),
                          ),
                        ],
                      ),
                      Text(user == null ? 'Estado: sin sesión' : 'Sesión: ${user.email}'),
                    ],
                  ),
                ),
              ),

              // ===== Reglas =====
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ListTile(
                      title: Text('Reglas (Asunto → Carpeta)'),
                      subtitle: Text('Se evalúan en orden; al coincidir, descarga los PDF a la carpeta indicada.'),
                    ),
                    const Divider(height: 1),
                    Obx(() => ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      onReorder: (oldIndex, newIndex) async {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final item = settings.rules.removeAt(oldIndex);
                        settings.rules.insert(newIndex, item);
                        await settings.save();
                      },
                      children: [
                        for (int i = 0; i < settings.rules.length; i++)
                          Dismissible(
                            key: ValueKey('${settings.rules[i].key}_$i'),
                            background: Container(color: Colors.redAccent),
                            onDismissed: (_) async {
                              settings.rules.removeAt(i);
                              await settings.save();
                            },
                            child: ListTile(
                              title: Text('Contiene: ${settings.rules[i].keyword}'),
                              subtitle: Text('Guardar en: ${settings.rules[i].relativeDir}'),
                              trailing: const Icon(Icons.drag_handle),
                            ),
                          ),
                      ],
                    )),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _showAddRuleDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar regla'),
                      ),
                    ),
                  ],
                ),
              ),

              // ===== Registro =====
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ListTile(title: Text('Registro')),
                    const Divider(height: 1),
                    Obx(() => Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        logger.log.value.isEmpty
                            ? 'Listo. Inicia sesión, pulsa “Sincronizar PDFs” y revisa “Archivos”.'
                            : logger.log.value,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    )),
                  ],
                ),
              ),

              // ===== Archivos =====
              const _FilesPaneEmbedded(),
            ],
          ),
        );
      }),
    );
  }
}

/// ============== Pane "Archivos" incrustado (sin scroll propio) ==============
class _FilesPaneEmbedded extends StatefulWidget {
  const _FilesPaneEmbedded({super.key});
  @override
  State<_FilesPaneEmbedded> createState() => _FilesPaneEmbeddedState();
}

class _FilesPaneEmbeddedState extends State<_FilesPaneEmbedded> {
  final checked = <String, bool>{}.obs; // path → seleccionado
  final loading = false.obs;
  final cache = <String, List<FileSystemEntity>>{}.obs; // rule.keyword → files

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final settings = Get.find<SettingsController>();
    final sync = Get.find<SyncController>();
    loading.value = true;
    cache.clear();
    checked.clear();

    for (final r in settings.rules) {
      final items = await sync.listPdfsForRule(r, onlyLastDays: settings.recentDays.value);
      cache[r.keyword] = items;
    }
    loading.value = false;
  }

  Future<void> _batchShareAndArchive() async {
    final settings = Get.find<SettingsController>();
    final sync = Get.find<SyncController>();
    loading.value = true;
    try {
      final selectedPaths = checked.entries.where((e) => e.value).map((e) => e.key).toList();
      for (final path in selectedPaths) {
        final rule = settings.rules.firstWhereOrNull((r) => path.contains('/${r.relativeDir}/'));
        if (rule == null) continue;
        await sync.shareToWhatsAndArchive(File(path), rule);
      }
    } finally {
      await _refresh();
      loading.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Obx(() {
          if (loading.value) return const Center(child: CircularProgressIndicator());

          final allCount = cache.values.fold<int>(0, (p, l) => p + l.length);
          final selected = checked.values.where((v) => v).length;

          final header = Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Actualizar'),
              ),
              FilledButton.icon(
                onPressed: selected == 0 ? null : _batchShareAndArchive,
                icon: const Icon(Icons.share),
                label: Text('Compartir y archivar ($selected/$allCount)'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Últimos días:'),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: Obx(() => TextField(
                      keyboardType: TextInputType.number,
                      controller: TextEditingController(text: settings.recentDays.value.toString()),
                      onSubmitted: (v) async {
                        settings.recentDays.value = (int.tryParse(v) ?? kDefaultDays).clamp(1, 365);
                        await settings.save();
                        _refresh();
                      },
                    )),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Whats +'),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 170,
                    child: Obx(() => TextField(
                      controller: TextEditingController(text: settings.whatsPhone.value),
                      onSubmitted: (v) async {
                        settings.whatsPhone.value = v.replaceAll(RegExp(r'\D'), '');
                        await settings.save();
                      },
                    )),
                  ),
                ],
              ),
            ],
          );

          final tiles = <Widget>[header, const SizedBox(height: 8)];

          for (final r in settings.rules) {
            final items = cache[r.keyword] ?? const <FileSystemEntity>[];
            tiles.add(ExpansionTile(
              title: Text('Carpeta de "${r.keyword}"'),
              subtitle: Text('Ruta: ${r.relativeDir} (${items.length} archivos, últimos ${settings.recentDays.value} días)'),
              children: items.isEmpty
                  ? [const ListTile(title: Text('Sin archivos PDF'))]
                  : items.map((e) {
                final f = File(e.path);
                final name = f.uri.pathSegments.last;
                final size = f.existsSync() ? f.lengthSync() : 0;
                final mtime = f.existsSync()
                    ? f.lastModifiedSync()
                    : DateTime.fromMillisecondsSinceEpoch(0);
                final key = f.path;
                final isChecked = checked[key] ?? false;

                return ListTile(
                  leading: Checkbox(
                    value: isChecked,
                    onChanged: (v) => checked[key] = v ?? false,
                  ),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${(size / 1024).toStringAsFixed(1)} KB    ${mtime.toLocal()}'),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.open_in_new),
                        tooltip: 'Abrir',
                        onPressed: () => Get.find<SyncController>().openFile(f),
                      ),
                      IconButton(
                        icon: const Icon(Icons.share),
                        tooltip: 'Compartir + archivar',
                        onPressed: () async {
                          await Get.find<SyncController>().shareToWhatsAndArchive(f, r);
                          checked.remove(key);
                          await _refresh();
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.send),
                        tooltip: 'Enviar seleccionados (nativo)',
                        onPressed: () async {
                          final selectedPaths = checked.entries.where((e) => e.value).map((e) => e.key).toList();
                          if (selectedPaths.isEmpty) return;

                          final files = selectedPaths.map((p) => File(p)).toList();
                          final phone = settings.whatsPhone.value; // ya lo tienes en tu app

                          try {
                            await NativeWhatsShare.shareMultiplePdfsNative(
                              files: files,
                              phone: phone,     // o null si NO quieres usar jid
                              forceBusiness: false,
                              useJid: true,     // true = intenta abrir chat del número; false = abre WhatsApp para elegir
                            );
                            // (opcional) luego archiva cada uno como ya haces
                            // for (final f in files) await sync.shareToWhatsAndArchive(f, reglaCorrespondiente);
                          } on PlatformException catch (e) {
                            Get.find<LogController>().add('Error nativo múltiples: ${e.code} ${e.message}');
                          } catch (e) {
                            Get.find<LogController>().add('Error nativo múltiples: $e');
                          }
                        },
                      ),
                    ],
                  ),
                  onTap: () => checked[key] = !isChecked,
                );
              }).toList(),
            ));
          }

          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: tiles);
        }),
      ),
    );
  }
}
