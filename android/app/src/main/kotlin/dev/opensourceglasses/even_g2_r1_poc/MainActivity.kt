package dev.opensourceglasses.even_g2_r1_poc

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val BACKGROUND_CHANNEL =
            "dev.opensourceglasses/background_connection"
        private const val BLUETOOTH_BOND_CHANNEL =
            "dev.opensourceglasses/r1_bond"
        private const val LC3_CHANNEL =
            "dev.opensourceglasses/workbench_lc3"
        private const val RUNTIME_CHANNEL =
            "dev.opensourceglasses/workbench_runtime"
        private const val STORAGE_CHANNEL =
            "dev.opensourceglasses/workbench_storage"
        private const val GEMMA_CHANNEL =
            "dev.opensourceglasses/workbench_gemma"
        private const val DEBUG_GESTURE_CHANNEL =
            "dev.opensourceglasses/workbench_debug_gesture"
        private const val DEBUG_GESTURE_ACTION =
            "dev.opensourceglasses.even_g2_r1_poc.SIMULATE_R1_GESTURE"
        private const val DEBUG_GESTURE_TYPE = "gesture_type"
        private const val STORAGE_PREFERENCES = "workbench_storage"
        private const val STORAGE_DIRECTORY_URI = "shared_audio_directory_uri"
        private const val STORAGE_DOCUMENT_INDEX = "shared_audio_document_index"
        private const val RUNTIME_DIAGNOSTIC_PREFERENCES =
            "workbench_runtime_diagnostics"
        private const val LAST_REPORTED_EXIT_TIMESTAMP =
            "last_reported_exit_timestamp"
        internal const val CORRECTION_PROMPT_FILE_NAME =
            "workbench-correction-prompt.txt"
        private const val MAX_CORRECTION_PROMPT_CHARACTERS = 10_000
        private const val CHOOSE_DIRECTORY_REQUEST = 4201
    }

    private var pendingDirectoryResult: MethodChannel.Result? = null
    private val storageExecutor = Executors.newSingleThreadExecutor()
    private val historyExecutor = Executors.newSingleThreadExecutor()
    private val sharedHistoryCache by lazy {
        SharedHistoryCache(applicationContext)
    }
    private lateinit var storageChannel: MethodChannel
    private var sharedAudioPlayer: MediaPlayer? = null
    private var sharedAudioFileName: String? = null
    private lateinit var gemmaBridge: GemmaCorrectionBridge
    private lateinit var debugGestureChannel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        reportPreviousProcessExits()
        debugGestureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEBUG_GESTURE_CHANNEL,
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BACKGROUND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "start" -> {
                    if (!BleConnectionService.isRunning) {
                        ContextCompat.startForegroundService(
                            applicationContext,
                            Intent(applicationContext, BleConnectionService::class.java),
                        )
                    }
                    result.success(null)
                }
                "stop" -> {
                    applicationContext.stopService(
                        Intent(applicationContext, BleConnectionService::class.java),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BLUETOOTH_BOND_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "bondState" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.error("missing_address", "R1 address is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val manager = getSystemService(BluetoothManager::class.java)
                        val adapter = manager.adapter
                        result.success(adapter?.getRemoteDevice(address)?.bondState)
                    } catch (error: Exception) {
                        result.error("bond_state", error.message, null)
                    }
                }
                "createBond" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.error("missing_address", "Bluetooth address is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val manager = getSystemService(BluetoothManager::class.java)
                        val device = manager.adapter?.getRemoteDevice(address)
                        result.success(
                            device != null &&
                                (device.bondState == android.bluetooth.BluetoothDevice.BOND_BONDED ||
                                    device.createBond()),
                        )
                    } catch (error: Exception) {
                        result.error("create_bond", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LC3_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    try {
                        result.success(WorkBenchLc3.initialize())
                    } catch (error: Throwable) {
                        result.error("lc3_initialize", error.message, null)
                    }
                }
                "decode" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val frameSize = call.argument<Int>("frameSize") ?: 40
                    if (bytes == null) {
                        result.error("lc3_input", "LC3 bytes are required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(WorkBenchLc3.decode(bytes, frameSize))
                    } catch (error: Throwable) {
                        result.error("lc3_decode", error.message, null)
                    }
                }
                "dispose" -> {
                    WorkBenchLc3.dispose()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RUNTIME_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "inferenceCapabilities" -> {
                    val activityManager =
                        getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val glesVersion =
                        activityManager.deviceConfigurationInfo.reqGlEsVersion
                    val hasNeuralNetworks =
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1
                    result.success(
                        mapOf(
                            "glesVersion" to glesVersion,
                            "hasGpu" to (glesVersion >= 0x00030000),
                            "hasNeuralNetworks" to hasNeuralNetworks,
                            "sdkInt" to Build.VERSION.SDK_INT,
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }
        storageChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL,
        )
        storageChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "currentDirectory" -> result.success(currentDirectory())
                "chooseDirectory" -> chooseDirectory(result)
                "clearDirectory" -> {
                    clearDirectory()
                    result.success(null)
                }
                "exportFiles" -> {
                    val paths = call.argument<List<String>>("paths")
                    if (paths == null) {
                        result.error(
                            "missing_paths",
                            "Audio or transcript files are required.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    exportFiles(paths, result)
                }
                "readCorrectionInstructions" ->
                    readCorrectionInstructions(result)
                "writeCorrectionInstructions" -> {
                    val instructions = call.argument<String>("instructions")
                    if (instructions == null) {
                        result.error(
                            "missing_instructions",
                            "Correction instructions are required.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    writeCorrectionInstructions(instructions, result)
                }
                "listTranscriptions" ->
                    listTranscriptions(
                        result,
                        reconcileShared =
                            call.argument<Boolean>("reconcileShared") == true,
                    )
                "listMessages" ->
                    listMessages(
                        result,
                        reconcileShared =
                            call.argument<Boolean>("reconcileShared") == true,
                    )
                "indexConversation" -> {
                    val turns =
                        call.argument<List<Map<String, Any?>>>("turns")
                    if (turns == null) {
                        result.error(
                            "missing_conversation",
                            "Conversation turns are required.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    indexConversation(turns, result)
                }
                "listConversations" -> listConversations(result)
                "playAudio" -> {
                    val fileName = call.argument<String>("fileName")
                    if (fileName == null) {
                        result.error(
                            "missing_audio",
                            "A saved WAV file is required.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    playAudio(fileName, result)
                }
                "stopAudio" -> {
                    stopSharedAudio()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        gemmaBridge = GemmaCorrectionBridge(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GEMMA_CHANNEL,
        ).setMethodCallHandler(gemmaBridge::handle)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        dispatchDebugGesture(intent)
    }

    private fun dispatchDebugGesture(intent: Intent) {
        val isDebuggable =
            applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (!isDebuggable || intent.action != DEBUG_GESTURE_ACTION) {
            return
        }
        val type = intent.getIntExtra(DEBUG_GESTURE_TYPE, -1)
        if (type !in 0..3) {
            Log.e(
                "WorkBench",
                "[WorkBench][DebugGesture] state=rejected reason=invalid_type",
            )
            return
        }
        if (!::debugGestureChannel.isInitialized) {
            Log.e(
                "WorkBench",
                "[WorkBench][DebugGesture] state=rejected reason=channel_unavailable",
            )
            return
        }
        debugGestureChannel.invokeMethod(
            "simulateR1Gesture",
            mapOf("type" to type),
        )
        Log.i(
            "WorkBench",
            "[WorkBench][DebugGesture] state=dispatched type=$type",
        )
    }

    private fun reportPreviousProcessExits() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return
        }
        historyExecutor.execute {
            runCatching {
                val preferences =
                    getSharedPreferences(
                        RUNTIME_DIAGNOSTIC_PREFERENCES,
                        Context.MODE_PRIVATE,
                    )
                val lastReported =
                    preferences.getLong(LAST_REPORTED_EXIT_TIMESTAMP, 0L)
                val manager = getSystemService(ActivityManager::class.java)
                val exits =
                    manager
                        .getHistoricalProcessExitReasons(packageName, 0, 8)
                        .filter { it.timestamp > lastReported }
                        .sortedBy { it.timestamp }
                for (exit in exits) {
                    val process =
                        if (exit.processName.endsWith(":gemma")) {
                            "gemma"
                        } else {
                            "app"
                        }
                    Log.i(
                        "WorkBench",
                        "[WorkBench][Runtime] state=previous_exit " +
                            "process=$process reason=${exitReason(exit.reason)} " +
                            "importance=${exit.importance} " +
                            "pss_kb=${exit.pss} rss_kb=${exit.rss}",
                    )
                }
                val newest = exits.maxOfOrNull { it.timestamp }
                if (newest != null) {
                    preferences
                        .edit()
                        .putLong(LAST_REPORTED_EXIT_TIMESTAMP, newest)
                        .apply()
                }
            }.onFailure {
                Log.i(
                    "WorkBench",
                    "[WorkBench][Runtime] state=previous_exit_unavailable",
                )
            }
        }
    }

    private fun exitReason(reason: Int): String =
        when (reason) {
            ApplicationExitInfo.REASON_LOW_MEMORY -> "low_memory"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "native_crash"
            ApplicationExitInfo.REASON_CRASH -> "crash"
            ApplicationExitInfo.REASON_ANR -> "anr"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE ->
                "excessive_resource_usage"
            ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency_died"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE ->
                "initialization_failure"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission_change"
            ApplicationExitInfo.REASON_SIGNALED -> "signaled"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "user_requested"
            ApplicationExitInfo.REASON_USER_STOPPED -> "user_stopped"
            else -> "other"
        }

    private fun chooseDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error(
                "directory_picker_active",
                "The folder picker is already open.",
                null,
            )
            return
        }
        pendingDirectoryResult = result
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
            }
        startActivityForResult(intent, CHOOSE_DIRECTORY_REQUEST)
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CHOOSE_DIRECTORY_REQUEST) {
            return
        }
        val result = pendingDirectoryResult ?: return
        pendingDirectoryResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val flags =
                data.flags and
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags)
            val preferences =
                getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
            if (preferences.getString(STORAGE_DIRECTORY_URI, null) != uri.toString()) {
                preferences.edit().remove(STORAGE_DOCUMENT_INDEX).apply()
                sharedHistoryCache.reset()
            }
            releaseStoredDirectory(except = uri)
            preferences.edit()
                .putString(STORAGE_DIRECTORY_URI, uri.toString())
                .apply()
            result.success(directoryMessage(uri))
        } catch (_: Exception) {
            result.error(
                "directory_access",
                "Could not retain access to that folder.",
                null,
            )
        }
    }

    private fun currentDirectory(): Map<String, String>? {
        val uri = storedDirectoryUri() ?: return null
        return try {
            directoryMessage(uri)
        } catch (_: Exception) {
            clearDirectory()
            null
        }
    }

    private fun directoryMessage(uri: Uri): Map<String, String> =
        mapOf("displayName" to directoryDisplayName(uri))

    private fun directoryDisplayName(uri: Uri): String {
        val documentUri =
            DocumentsContract.buildDocumentUriUsingTree(
                uri,
                DocumentsContract.getTreeDocumentId(uri),
            )
        contentResolver.query(
            documentUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val displayName = cursor.getString(0)?.trim()
                if (!displayName.isNullOrEmpty()) {
                    return displayName
                }
            }
        }
        return "Selected folder"
    }

    private fun storedDirectoryUri(): Uri? {
        val raw =
            getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
                .getString(STORAGE_DIRECTORY_URI, null)
                ?: return null
        val uri = Uri.parse(raw)
        val retained =
            contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isReadPermission && it.isWritePermission
            }
        if (!retained) {
            getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .remove(STORAGE_DIRECTORY_URI)
                .apply()
            sharedHistoryCache.reset()
            return null
        }
        return uri
    }

    private fun clearDirectory() {
        releaseStoredDirectory()
        getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .remove(STORAGE_DIRECTORY_URI)
            .remove(STORAGE_DOCUMENT_INDEX)
            .apply()
        sharedHistoryCache.reset()
    }

    private fun releaseStoredDirectory(except: Uri? = null) {
        val raw =
            getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
                .getString(STORAGE_DIRECTORY_URI, null)
                ?: return
        val uri = Uri.parse(raw)
        if (uri == except) {
            return
        }
        try {
            contentResolver.releasePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            // The provider may already have revoked access.
        }
    }

    private fun exportFiles(
        paths: List<String>,
        result: MethodChannel.Result,
    ) {
        val directory = storedDirectoryUri()
        if (directory == null) {
            result.error(
                "directory_unavailable",
                "Choose the shared save folder again.",
                null,
            )
            return
        }
        storageExecutor.execute {
            try {
                var exported = 0
                for (path in paths.distinct()) {
                    if (exportInternalFile(directory, path)) {
                        exported++
                    }
                }
                runOnUiThread { result.success(exported) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "export_failed",
                        "Could not save files to the selected folder.",
                        null,
                    )
                }
            }
        }
    }

    private fun exportInternalFile(
        directory: Uri,
        sourcePath: String,
    ): Boolean {
        val source = File(sourcePath).canonicalFile
        val internalRoot = filesDir.canonicalFile
        if (!source.isFile ||
            !source.path.startsWith("${internalRoot.path}${File.separator}")
        ) {
            throw SecurityException("Source is outside app storage.")
        }
        val mimeType =
            when (source.extension.lowercase()) {
                "wav" -> "audio/wav"
                "txt" -> "text/plain"
                else -> throw IllegalArgumentException("Unsupported export type.")
            }
        val rootDocument =
            DocumentsContract.buildDocumentUriUsingTree(
                directory,
                DocumentsContract.getTreeDocumentId(directory),
            )
        val indexedTarget = indexedDocument(directory, source.name)
        if (indexedTarget != null) {
            if (sharedHistoryCache.isCurrentExport(source)) {
                return false
            }
            if (!sharedHistoryCache.hasExportRecord(source.name) ||
                sharedDocumentIsCurrent(indexedTarget, source)
            ) {
                updateHistoryCache(source)
                sharedHistoryCache.markExported(source)
                return false
            }
        }
        val target =
            indexedTarget
                ?: findChild(directory, source.name)
                ?: predictableExternalStorageChild(directory, source.name)
                ?: DocumentsContract.createDocument(
                    contentResolver,
                    rootDocument,
                    mimeType,
                    source.name,
                )
                ?: throw IllegalStateException("The document provider rejected the file.")
        source.inputStream().use { input ->
            contentResolver.openOutputStream(target, "wt")?.use { output ->
                input.copyTo(output)
                output.flush()
            } ?: throw IllegalStateException("The document provider is not writable.")
        }
        rememberDocument(source.name, target)
        updateHistoryCache(source)
        sharedHistoryCache.markExported(source)
        return true
    }

    private fun updateHistoryCache(source: File) {
        try {
            sharedHistoryCache.indexExportedFile(source)
        } catch (_: Exception) {
            try {
                sharedHistoryCache.invalidateSnapshots()
            } catch (_: Exception) {
                // A later cache read falls back to the shared document scan.
            }
            Log.w(
                "WorkBench",
                "[WorkBench][SharedStorage] state=history_cache_update_failed " +
                    "fallback=shared_scan",
            )
        }
    }

    private fun sharedDocumentIsCurrent(
        document: Uri,
        source: File,
    ): Boolean {
        val sourceModified = source.lastModified()
        val documentModified = documentLastModified(document)
        return sourceModified > 0 &&
            documentModified > 0 &&
            documentModified >= sourceModified
    }

    private fun findChild(
        directory: Uri,
        displayName: String,
    ): Uri? {
        val children =
            DocumentsContract.buildChildDocumentsUriUsingTree(
                directory,
                DocumentsContract.getTreeDocumentId(directory),
            )
        val projection =
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
        contentResolver.query(children, projection, null, null, null)?.use { cursor ->
            val idColumn =
                cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                )
            val nameColumn =
                cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                )
            while (cursor.moveToNext()) {
                if (cursor.getString(nameColumn) == displayName) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        directory,
                        cursor.getString(idColumn),
                    )
                }
            }
        }
        return null
    }

    private fun readCorrectionInstructions(result: MethodChannel.Result) {
        val directory = storedDirectoryUri()
        if (directory == null) {
            result.error(
                "directory_unavailable",
                "Choose the shared save folder again.",
                null,
            )
            return
        }
        storageExecutor.execute {
            try {
                val document =
                    indexedDocument(directory, CORRECTION_PROMPT_FILE_NAME)
                        ?: findChild(directory, CORRECTION_PROMPT_FILE_NAME)
                        ?: predictableExternalStorageChild(
                            directory,
                            CORRECTION_PROMPT_FILE_NAME,
                        )
                val instructions = document?.let(::readTranscriptText)
                Log.i(
                    "WorkBench",
                    "[WorkBench][SharedStorage] state=prompt_read " +
                        "found=${document != null}",
                )
                runOnUiThread { result.success(instructions) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "prompt_read_failed",
                        "Could not read the correction prompt.",
                        null,
                    )
                }
            }
        }
    }

    private fun writeCorrectionInstructions(
        instructions: String,
        result: MethodChannel.Result,
    ) {
        val validated = validateCorrectionInstructions(instructions)
        if (validated == null) {
            result.error(
                "invalid_instructions",
                "Correction instructions must contain 1 to 10000 valid characters.",
                null,
            )
            return
        }
        val directory = storedDirectoryUri()
        if (directory == null) {
            result.error(
                "directory_unavailable",
                "Choose the shared save folder again.",
                null,
            )
            return
        }
        storageExecutor.execute {
            try {
                val rootDocument =
                    DocumentsContract.buildDocumentUriUsingTree(
                        directory,
                        DocumentsContract.getTreeDocumentId(directory),
                    )
                val document =
                    indexedDocument(directory, CORRECTION_PROMPT_FILE_NAME)
                        ?: findChild(directory, CORRECTION_PROMPT_FILE_NAME)
                        ?: predictableExternalStorageChild(
                            directory,
                            CORRECTION_PROMPT_FILE_NAME,
                        )
                        ?: DocumentsContract.createDocument(
                            contentResolver,
                            rootDocument,
                            "text/plain",
                            CORRECTION_PROMPT_FILE_NAME,
                        )
                        ?: throw IllegalStateException(
                            "The document provider rejected the prompt.",
                        )
                contentResolver.openOutputStream(document, "wt")?.use { output ->
                    output.writer(Charsets.UTF_8).use { writer ->
                        writer.write(validated)
                        writer.write("\n")
                        writer.flush()
                    }
                } ?: throw IllegalStateException(
                    "The document provider is not writable.",
                )
                rememberDocument(CORRECTION_PROMPT_FILE_NAME, document)
                Log.i(
                    "WorkBench",
                    "[WorkBench][SharedStorage] state=prompt_saved",
                )
                runOnUiThread { result.success(null) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "prompt_write_failed",
                        "Could not save the correction prompt.",
                        null,
                    )
                }
            }
        }
    }

    private fun validateCorrectionInstructions(value: String): String? {
        val trimmed = value.trim()
        if (trimmed.isEmpty() ||
            trimmed.length > MAX_CORRECTION_PROMPT_CHARACTERS
        ) {
            return null
        }
        for (character in trimmed) {
            if (character.code < 0x20 &&
                character != '\t' &&
                character != '\n' &&
                character != '\r'
            ) {
                return null
            }
        }
        return trimmed
    }

    private fun listTranscriptions(
        result: MethodChannel.Result,
        reconcileShared: Boolean,
    ) {
        val directory = storedDirectoryUri()
        if (directory == null) {
            result.error(
                "directory_unavailable",
                "Choose the shared save folder again.",
                null,
            )
            return
        }
        historyExecutor.execute {
            try {
                var source = "cache"
                val entries =
                    if (reconcileShared ||
                        !sharedHistoryCache.hasTranscriptSnapshot()
                    ) {
                        try {
                            readSharedTranscriptions(directory).also {
                                sharedHistoryCache.replaceTranscripts(it)
                                source = "shared"
                            }
                        } catch (error: Exception) {
                            val cached = sharedHistoryCache.listTranscripts()
                            if (cached.isEmpty()) {
                                throw error
                            }
                            source = "cache_fallback"
                            cached
                        }
                    } else {
                        sharedHistoryCache.listTranscripts()
                    }
                Log.i(
                    "WorkBench",
                    "[WorkBench][SharedStorage] state=list_ready " +
                        "source=$source " +
                        "transcriptions=${entries.size}",
                )
                runOnUiThread { result.success(entries) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "list_failed",
                        "Could not read transcriptions from the selected folder.",
                        null,
                    )
                }
            }
        }
    }

    private fun readSharedTranscriptions(
        directory: Uri,
    ): List<Map<String, Any?>> {
        data class Entry(
            var originalDocument: Uri? = null,
            var legacyDocument: Uri? = null,
            var correctedDocument: Uri? = null,
            var audioFileName: String? = null,
            var updatedAtMillis: Long = 0,
        )
        data class SharedFile(val transcriptId: String, val kind: String)

        fun classify(name: String): SharedFile? {
            val lower = name.lowercase()
            if (name.isEmpty() ||
                lower == CORRECTION_PROMPT_FILE_NAME ||
                lower.endsWith(".message.txt") ||
                lower.endsWith(".part.wav") ||
                lower.endsWith(".part.txt")
            ) {
                return null
            }
            val suffix =
                when {
                    lower.endsWith(".corrected.txt") -> ".corrected.txt"
                    lower.endsWith(".raw.txt") -> ".raw.txt"
                    lower.endsWith(".txt") -> ".txt"
                    lower.endsWith(".wav") -> ".wav"
                    else -> return null
                }
            val id = name.dropLast(suffix.length)
            if (id.isEmpty()) {
                return null
            }
            val kind =
                when (suffix) {
                    ".corrected.txt" -> "corrected"
                    ".raw.txt" -> "original"
                    ".txt" -> "legacy"
                    else -> "audio"
                }
            return SharedFile(id, kind)
        }

        val children =
            DocumentsContract.buildChildDocumentsUriUsingTree(
                directory,
                DocumentsContract.getTreeDocumentId(directory),
            )
        val projection =
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
        val byId = mutableMapOf<String, Entry>()
        var documentCount = 0
        var indexedDocumentCount = 0
        var wavFileCount = 0
        var transcriptFileCount = 0

        fun indexDocument(
            name: String,
            document: Uri,
            modifiedAtMillis: Long,
        ) {
            val sharedFile = classify(name) ?: return
            val entry = byId.getOrPut(sharedFile.transcriptId) { Entry() }
            entry.updatedAtMillis =
                maxOf(entry.updatedAtMillis, modifiedAtMillis)
            when (sharedFile.kind) {
                "audio" -> {
                    wavFileCount++
                    entry.audioFileName = name
                }
                "original" -> {
                    transcriptFileCount++
                    entry.originalDocument = document
                }
                "corrected" -> {
                    transcriptFileCount++
                    entry.correctedDocument = document
                }
                else -> {
                    transcriptFileCount++
                    entry.legacyDocument = document
                }
            }
        }

        for ((name, document) in documentIndex()) {
            if (!documentBelongsToTree(directory, document) || !documentExists(document)) {
                continue
            }
            indexedDocumentCount++
            indexDocument(name, document, documentLastModified(document))
        }
        contentResolver.query(children, projection, null, null, null)?.use { cursor ->
            val idColumn =
                cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                )
            val nameColumn =
                cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                )
            val modifiedColumn =
                cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                )
            while (cursor.moveToNext()) {
                documentCount++
                val name = cursor.getString(nameColumn)?.trim().orEmpty()
                val modified =
                    if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) {
                        cursor.getLong(modifiedColumn)
                    } else {
                        0L
                    }
                val document =
                    DocumentsContract.buildDocumentUriUsingTree(
                        directory,
                        cursor.getString(idColumn),
                    )
                indexDocument(name, document, modified)
            }
        }
        val results = mutableListOf<Map<String, Any?>>()
        var readableTranscriptCount = 0
        val sortedEntries =
            byId.entries.sortedWith(
                compareByDescending<Map.Entry<String, Entry>> {
                    it.value.updatedAtMillis
                }.thenByDescending { it.key },
            )
        for ((id, entry) in sortedEntries) {
            val originalDocument =
                entry.originalDocument ?: entry.legacyDocument ?: continue
            val originalText =
                try {
                    readTranscriptText(originalDocument)
                } catch (_: Exception) {
                    ""
                }
            if (originalText.isEmpty()) {
                continue
            }
            readableTranscriptCount++
            val correctedText =
                entry.correctedDocument?.let { document ->
                    try {
                        readTranscriptText(document).ifEmpty { null }
                    } catch (_: Exception) {
                        null
                    }
                }
            results.add(
                mapOf(
                    "id" to id,
                    "originalText" to originalText,
                    "correctedText" to correctedText,
                    "audioFileName" to entry.audioFileName,
                    "updatedAtMillis" to entry.updatedAtMillis,
                ),
            )
            if (results.size == SharedHistoryCache.MAX_VISIBLE_TRANSCRIPTS) {
                break
            }
        }
        Log.i(
            "WorkBench",
            "[WorkBench][SharedStorage] state=list_scan " +
                "provider_documents=$documentCount " +
                "indexed_documents=$indexedDocumentCount " +
                "wav_files=$wavFileCount " +
                "transcript_files=$transcriptFileCount " +
                "readable_transcripts=$readableTranscriptCount",
        )
        return results
    }

    private fun listMessages(
        result: MethodChannel.Result,
        reconcileShared: Boolean,
    ) {
        val directory = storedDirectoryUri()
        if (directory == null) {
            result.error(
                "directory_unavailable",
                "Choose the shared save folder again.",
                null,
            )
            return
        }
        historyExecutor.execute {
            try {
                var source = "cache"
                val entries =
                    if (reconcileShared ||
                        !sharedHistoryCache.hasMessageSnapshot()
                    ) {
                        try {
                            readSharedMessages(directory).also {
                                sharedHistoryCache.replaceMessages(it)
                                source = "shared"
                            }
                        } catch (error: Exception) {
                            val cached = sharedHistoryCache.listMessages()
                            if (cached.isEmpty()) {
                                throw error
                            }
                            source = "cache_fallback"
                            cached
                        }
                    } else {
                        sharedHistoryCache.listMessages()
                    }
                Log.i(
                    "WorkBench",
                    "[WorkBench][SharedStorage] state=message_list_ready " +
                        "source=$source " +
                        "messages=${entries.size}",
                )
                runOnUiThread { result.success(entries) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "message_list_failed",
                        "Could not read messages from the selected folder.",
                        null,
                    )
                }
            }
        }
    }

    private fun indexConversation(
        turns: List<Map<String, Any?>>,
        result: MethodChannel.Result,
    ) {
        historyExecutor.execute {
            try {
                sharedHistoryCache.replaceConversationTurns(turns)
                Log.i(
                    "WorkBench",
                    "[WorkBench][Conversation] state=indexed " +
                        "turns=${turns.size}",
                )
                runOnUiThread { result.success(null) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "conversation_index_failed",
                        "Could not index the saved conversation.",
                        null,
                    )
                }
            }
        }
    }

    private fun listConversations(result: MethodChannel.Result) {
        historyExecutor.execute {
            try {
                val entries = sharedHistoryCache.listConversationTurns()
                Log.i(
                    "WorkBench",
                    "[WorkBench][Conversation] state=list_ready " +
                        "turns=${entries.size}",
                )
                runOnUiThread { result.success(entries) }
            } catch (_: Exception) {
                runOnUiThread {
                    result.error(
                        "conversation_list_failed",
                        "Could not read saved conversations.",
                        null,
                    )
                }
            }
        }
    }

    private fun readSharedMessages(
        directory: Uri,
    ): List<Map<String, Any?>> {
        data class Entry(
            val id: String,
            val direction: String,
            val document: Uri,
            val updatedAtMillis: Long,
        )

        fun direction(name: String): String? {
            val lower = name.lowercase()
            return when {
                lower.endsWith(".sent.message.txt") -> "sent"
                lower.endsWith(".received.message.txt") -> "received"
                else -> null
            }
        }

        val byName = mutableMapOf<String, Entry>()
        for ((name, document) in documentIndex()) {
            val messageDirection = direction(name) ?: continue
            if (!documentBelongsToTree(directory, document) ||
                !documentExists(document)
            ) {
                continue
            }
            byName[name] =
                Entry(
                    id = name,
                    direction = messageDirection,
                    document = document,
                    updatedAtMillis = documentLastModified(document),
                )
        }

        val children =
            DocumentsContract.buildChildDocumentsUriUsingTree(
                directory,
                DocumentsContract.getTreeDocumentId(directory),
            )
        val projection =
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
        contentResolver.query(children, projection, null, null, null)?.use { cursor ->
            val idColumn =
                cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                )
            val nameColumn =
                cursor.getColumnIndexOrThrow(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                )
            val modifiedColumn =
                cursor.getColumnIndex(
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                )
            while (cursor.moveToNext()) {
                val name = cursor.getString(nameColumn)?.trim().orEmpty()
                val messageDirection = direction(name) ?: continue
                val document =
                    DocumentsContract.buildDocumentUriUsingTree(
                        directory,
                        cursor.getString(idColumn),
                    )
                val modified =
                    if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) {
                        cursor.getLong(modifiedColumn)
                    } else {
                        documentLastModified(document)
                    }
                byName[name] =
                    Entry(
                        id = name,
                        direction = messageDirection,
                        document = document,
                        updatedAtMillis = modified,
                    )
            }
        }
        val results = mutableListOf<Map<String, Any?>>()
        val sortedEntries =
            byName.values.sortedWith(
                compareByDescending<Entry> { it.updatedAtMillis }
                    .thenByDescending { it.id },
            )
        for (entry in sortedEntries) {
            val text =
                try {
                    readTranscriptText(entry.document)
                } catch (_: Exception) {
                    ""
                }
            if (text.isEmpty()) {
                continue
            }
            results.add(
                mapOf(
                    "id" to entry.id,
                    "direction" to entry.direction,
                    "text" to text,
                    "updatedAtMillis" to entry.updatedAtMillis,
                ),
            )
            if (results.size == SharedHistoryCache.MAX_VISIBLE_MESSAGES) {
                break
            }
        }
        return results
    }

    private fun playAudio(
        fileName: String,
        result: MethodChannel.Result,
    ) {
        if (fileName.contains("/") ||
            fileName.contains("\\") ||
            !fileName.lowercase().endsWith(".wav")
        ) {
            result.error("invalid_audio", "The saved audio name is invalid.", null)
            return
        }
        val directory = storedDirectoryUri()
        val document =
            directory?.let {
                indexedDocument(it, fileName) ?: findChild(it, fileName)
            }
        if (document == null) {
            result.error("audio_missing", "The saved WAV file is unavailable.", null)
            return
        }
        stopSharedAudio()
        val player = MediaPlayer()
        var resultPending = true
        sharedAudioPlayer = player
        sharedAudioFileName = fileName
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
        )
        player.setOnPreparedListener { prepared ->
            if (sharedAudioPlayer !== prepared) {
                return@setOnPreparedListener
            }
            prepared.start()
            Log.i(
                "WorkBench",
                "[WorkBench][SharedStorage] state=playback_started " +
                    "source=shared_folder",
            )
            if (resultPending) {
                resultPending = false
                result.success(null)
            }
        }
        player.setOnCompletionListener { completed ->
            if (sharedAudioPlayer !== completed) {
                return@setOnCompletionListener
            }
            val completedName = sharedAudioFileName
            stopSharedAudio()
            Log.i(
                "WorkBench",
                "[WorkBench][SharedStorage] state=playback_completed " +
                    "source=shared_folder",
            )
            storageChannel.invokeMethod(
                "playbackCompleted",
                mapOf("fileName" to completedName),
            )
        }
        player.setOnErrorListener { failed, _, _ ->
            if (sharedAudioPlayer === failed) {
                val failedName = sharedAudioFileName
                stopSharedAudio()
                if (resultPending) {
                    resultPending = false
                    result.error(
                        "audio_playback",
                        "The saved WAV file could not be played.",
                        null,
                    )
                } else {
                    storageChannel.invokeMethod(
                        "playbackCompleted",
                        mapOf("fileName" to failedName),
                    )
                }
            }
            true
        }
        try {
            player.setDataSource(applicationContext, document)
            player.prepareAsync()
        } catch (_: Exception) {
            stopSharedAudio()
            if (resultPending) {
                resultPending = false
                result.error(
                    "audio_playback",
                    "The saved WAV file could not be opened.",
                    null,
                )
            }
        }
    }

    private fun readTranscriptText(document: Uri): String {
        val input = contentResolver.openInputStream(document) ?: return ""
        return input.bufferedReader(Charsets.UTF_8).use { reader ->
            val text = StringBuilder()
            val buffer = CharArray(4096)
            while (text.length < 65_536) {
                val remaining = minOf(buffer.size, 65_536 - text.length)
                val count = reader.read(buffer, 0, remaining)
                if (count <= 0) {
                    break
                }
                text.append(buffer, 0, count)
            }
            text.toString().trim()
        }
    }

    private fun documentIndex(): MutableMap<String, Uri> {
        val stored =
            getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
                .getStringSet(STORAGE_DOCUMENT_INDEX, emptySet())
                .orEmpty()
        val documents = mutableMapOf<String, Uri>()
        for (value in stored) {
            val separator = value.indexOf('\n')
            if (separator <= 0 || separator == value.lastIndex) {
                continue
            }
            val name = value.substring(0, separator)
            val uri = Uri.parse(value.substring(separator + 1))
            documents[name] = uri
        }
        return documents
    }

    private fun rememberDocument(
        name: String,
        document: Uri,
    ) {
        val documents = documentIndex()
        documents[name] = document
        val stored = documents.map { (key, value) -> "$key\n$value" }.toSet()
        getSharedPreferences(STORAGE_PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(STORAGE_DOCUMENT_INDEX, stored)
            .apply()
    }

    private fun indexedDocument(
        directory: Uri,
        name: String,
    ): Uri? {
        val document = documentIndex()[name] ?: return null
        return document.takeIf {
            documentBelongsToTree(directory, it) && documentExists(it)
        }
    }

    private fun predictableExternalStorageChild(
        directory: Uri,
        name: String,
    ): Uri? {
        if (directory.authority != "com.android.externalstorage.documents") {
            return null
        }
        val parentId = DocumentsContract.getTreeDocumentId(directory)
        val document =
            DocumentsContract.buildDocumentUriUsingTree(
                directory,
                "$parentId/$name",
            )
        return document.takeIf(::documentExists)
    }

    private fun documentBelongsToTree(
        directory: Uri,
        document: Uri,
    ): Boolean =
        try {
            directory.authority == document.authority &&
                DocumentsContract.getTreeDocumentId(directory) ==
                DocumentsContract.getTreeDocumentId(document)
        } catch (_: IllegalArgumentException) {
            false
        }

    private fun documentExists(document: Uri): Boolean =
        try {
            contentResolver.query(
                document,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )?.use { it.moveToFirst() } == true
        } catch (_: Exception) {
            false
        }

    private fun documentLastModified(document: Uri): Long =
        try {
            contentResolver.query(
                document,
                arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) {
                    cursor.getLong(0)
                } else {
                    0L
                }
            } ?: 0L
        } catch (_: Exception) {
            0L
        }

    private fun stopSharedAudio() {
        val player = sharedAudioPlayer
        sharedAudioPlayer = null
        sharedAudioFileName = null
        if (player != null) {
            try {
                player.stop()
            } catch (_: IllegalStateException) {
                // A player still preparing can be released without stopping.
            }
            player.reset()
            player.release()
        }
    }

    override fun onDestroy() {
        pendingDirectoryResult?.error(
            "activity_closed",
            "The folder picker was closed.",
            null,
        )
        pendingDirectoryResult = null
        if (::gemmaBridge.isInitialized) {
            gemmaBridge.dispose()
        }
        stopSharedAudio()
        storageExecutor.shutdown()
        historyExecutor.shutdown()
        WorkBenchLc3.dispose()
        super.onDestroy()
    }
}
