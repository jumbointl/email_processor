package com.solexpresspy.email_processor

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.solexpresspy.email_processor/whshare"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // Enviar uno o varios PDFs a WhatsApp (o WhatsApp Business)
                "sharePdfToWhatsApp" -> {
                    try {
                        // Acepta 'path' (String) o 'paths' (List<String>)
                        val singlePath = call.argument<String>("path")
                        val pathsList = call.argument<List<String>>("paths") // puede venir null
                        val mime = call.argument<String>("mime") ?: "application/pdf"
                        var phone = (call.argument<String>("phone") ?: "").trim()
                        val useBusiness = call.argument<Boolean>("useBusiness") ?: false
                        val useJid = call.argument<Boolean>("useJid") ?: true

                        // Normaliza teléfono: solo dígitos, sin '+'
                        phone = phone.replace(Regex("\\D+"), "")
                        if (useJid && phone.isEmpty()) {
                            return@setMethodCallHandler result.error("PHONE_ERROR", "Teléfono vacío o inválido", null)
                        }

                        val pkg = if (useBusiness) "com.whatsapp.w4b" else "com.whatsapp"

                        // Resuelve archivos
                        val files = mutableListOf<File>()
                        if (pathsList != null && pathsList.isNotEmpty()) {
                            for (p in pathsList) {
                                val f = File(p)
                                if (!f.exists()) return@setMethodCallHandler result.error("FILE_ERROR", "No existe: $p", null)
                                files.add(f)
                            }
                        } else if (singlePath != null) {
                            val f = File(singlePath)
                            if (!f.exists()) return@setMethodCallHandler result.error("FILE_ERROR", "No existe: $singlePath", null)
                            files.add(f)
                        } else {
                            return@setMethodCallHandler result.error("ARG_ERROR", "Debe proveer 'path' o 'paths'", null)
                        }

                        sendMultiplePdfsToWhatsApp(pkg, files, mime, phone, useJid)
                        result.success(true)

                    } catch (e: Exception) {
                        result.error("INTENT_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Envía 1..N PDFs a WhatsApp usando ACTION_SEND_MULTIPLE (solo archivos, sin texto). */
    private fun sendMultiplePdfsToWhatsApp(
        pkg: String,
        files: List<File>,
        mime: String,
        phone: String,
        useJid: Boolean
    ) {
        val uris = ArrayList<Uri>(files.size)
        val authority = "${applicationContext.packageName}.provider"

        for (f in files) {
            val uri = FileProvider.getUriForFile(applicationContext, authority, f)
            uris.add(uri)
        }

        val sendIntent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "application/pdf" // importante para documentos
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            `package` = pkg
            if (useJid && phone.isNotEmpty()) {
                putExtra("jid", "$phone@s.whatsapp.net")
            }
            // Sin EXTRA_TEXT para máxima compatibilidad
        }

        // Concede permiso de lectura para cada URI
        for (u in uris) {
            grantUriPermission(pkg, u, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        // Compatibilidad (algunos OEMs requieren clipData con todas las URIs)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN) {
            if (uris.isNotEmpty()) {
                val clip = ClipData.newRawUri("shared_file", uris[0])
                for (i in 1 until uris.size) {
                    clip.addItem(ClipData.Item(uris[i]))
                }
                sendIntent.clipData = clip
            }
        }

        val pm = applicationContext.packageManager
        sendIntent.resolveActivity(pm) ?: throw IllegalStateException("WhatsApp no instalado ($pkg)")

        startActivity(sendIntent)
    }
}
