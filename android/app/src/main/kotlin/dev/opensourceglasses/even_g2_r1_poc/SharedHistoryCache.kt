package dev.opensourceglasses.even_g2_r1_poc

import android.content.ContentValues
import android.content.Context
import android.database.DatabaseUtils
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File

/**
 * App-private SQLite index for the Files-visible history.
 *
 * The shared files remain the interoperable source of truth. This index avoids
 * reopening every text document whenever history becomes active.
 */
internal class SharedHistoryCache(
    context: Context,
) : SQLiteOpenHelper(
        context,
        DATABASE_NAME,
        null,
        DATABASE_VERSION,
    ) {
    companion object {
        private const val DATABASE_NAME = "workbench_shared_history.db"
        private const val DATABASE_VERSION = 4
        private const val RECOVERY_SNAPSHOT_VERSION = 1
        private const val MAX_RECOVERY_SNAPSHOT_BYTES = 128L * 1024L * 1024L

        private const val TABLE_META = "cache_meta"
        private const val TABLE_TRANSCRIPTS = "transcripts"
        private const val TABLE_MESSAGES = "messages"
        private const val TABLE_CONVERSATIONS = "conversation_turns"
        private const val TABLE_EXPORTS = "exports"

        private const val META_TRANSCRIPTS_SNAPSHOT = "transcripts_snapshot"
        private const val META_MESSAGES_SNAPSHOT = "messages_snapshot"
        private const val MAX_TEXT_CHARACTERS = 65_536
        private const val RECOVERED_SPEAKER_PREFIX = "shared-text:"
        internal const val MAX_VISIBLE_TRANSCRIPTS = 100
        internal const val MAX_VISIBLE_MESSAGES = 100
        internal const val MAX_VISIBLE_CONVERSATION_TURNS = 100
        private val TRANSCRIPT_COLUMNS =
            arrayOf(
                "transcript_id",
                "raw_text",
                "legacy_text",
                "corrected_text",
                "audio_file_name",
                "updated_at_millis",
            )
        private val MESSAGE_COLUMNS =
            arrayOf(
                "message_id",
                "direction",
                "message_text",
                "updated_at_millis",
            )
        private val CONVERSATION_COLUMNS =
            arrayOf(
                "turn_id",
                "conversation_id",
                "speaker_id",
                "speaker_label",
                "turn_text",
                "start_ms",
                "end_ms",
                "confidence",
                "is_primary",
                "is_overlap",
                "updated_at_millis",
            )
    }

    override fun onCreate(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE $TABLE_META (
                cache_key TEXT PRIMARY KEY NOT NULL,
                cache_value INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE TABLE $TABLE_TRANSCRIPTS (
                transcript_id TEXT PRIMARY KEY NOT NULL,
                raw_text TEXT,
                legacy_text TEXT,
                corrected_text TEXT,
                audio_file_name TEXT,
                updated_at_millis INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE TABLE $TABLE_MESSAGES (
                message_id TEXT PRIMARY KEY NOT NULL,
                direction TEXT NOT NULL,
                message_text TEXT NOT NULL,
                updated_at_millis INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE TABLE $TABLE_EXPORTS (
                file_name TEXT PRIMARY KEY NOT NULL,
                file_size INTEGER NOT NULL,
                modified_at_millis INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        createConversationTable(database)
        database.execSQL(
            "CREATE INDEX transcripts_updated_idx " +
                "ON $TABLE_TRANSCRIPTS(updated_at_millis DESC)",
        )
        database.execSQL(
            "CREATE INDEX messages_updated_idx " +
                "ON $TABLE_MESSAGES(updated_at_millis DESC)",
        )
    }

    override fun onUpgrade(
        database: SQLiteDatabase,
        oldVersion: Int,
        newVersion: Int,
    ) {
        if (oldVersion < 2) {
            database.execSQL("DROP TABLE IF EXISTS $TABLE_META")
            database.execSQL("DROP TABLE IF EXISTS $TABLE_TRANSCRIPTS")
            database.execSQL("DROP TABLE IF EXISTS $TABLE_MESSAGES")
            database.execSQL("DROP TABLE IF EXISTS $TABLE_EXPORTS")
            onCreate(database)
            return
        }
        if (oldVersion < 3) {
            createConversationTable(database)
        }
        if (oldVersion < 4) {
            // Earlier snapshots indexed only the first UI page. Preserve the
            // cached rows, but force one source-of-truth rescan so scrolling
            // can reach the expanded retained history window.
            database.delete(TABLE_META, null, null)
        }
    }

    @Synchronized
    fun reset() {
        writableDatabase.runInTransaction {
            delete(TABLE_META, null, null)
            delete(TABLE_TRANSCRIPTS, null, null)
            delete(TABLE_MESSAGES, null, null)
            delete(TABLE_CONVERSATIONS, null, null)
            delete(TABLE_EXPORTS, null, null)
        }
    }

    @Synchronized
    fun invalidateSnapshots() {
        writableDatabase.delete(TABLE_META, null, null)
    }

    @Synchronized
    fun hasTranscriptSnapshot(): Boolean =
        hasSnapshot(META_TRANSCRIPTS_SNAPSHOT)

    @Synchronized
    fun hasMessageSnapshot(): Boolean =
        hasSnapshot(META_MESSAGES_SNAPSHOT)

    @Synchronized
    fun replaceTranscripts(entries: List<Map<String, Any?>>) {
        writableDatabase.runInTransaction {
            delete(TABLE_TRANSCRIPTS, null, null)
            for (entry in entries) {
                val id = (entry["id"] as? String)?.trim().orEmpty()
                val originalText =
                    (entry["originalText"] as? String)?.trim().orEmpty()
                val updatedAtMillis =
                    (entry["updatedAtMillis"] as? Number)?.toLong()
                if (id.isEmpty() ||
                    originalText.isEmpty() ||
                    updatedAtMillis == null
                ) {
                    continue
                }
                val values =
                    ContentValues().apply {
                        put("transcript_id", id)
                        put("raw_text", originalText)
                        putNullableText(
                            "corrected_text",
                            entry["correctedText"] as? String,
                        )
                        putNullableText(
                            "audio_file_name",
                            entry["audioFileName"] as? String,
                        )
                        put("updated_at_millis", updatedAtMillis)
                    }
                insertWithOnConflict(
                    TABLE_TRANSCRIPTS,
                    null,
                    values,
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            markSnapshot(this, META_TRANSCRIPTS_SNAPSHOT)
        }
    }

    /**
     * Rebuilds display-only speaker turns from shared `.conversation.txt`
     * exports when the original app-private JSON/index is unavailable.
     *
     * Exact native rows win whenever they still exist. The readable export
     * does not contain voice signatures or match confidence, so recovered
     * rows deliberately use stable synthetic speaker IDs and zero confidence.
     */
    @Synchronized
    fun reconcileConversationTurnsFromTranscripts(): Int {
        var recovered = 0
        writableDatabase.runInTransaction {
            query(
                TABLE_TRANSCRIPTS,
                arrayOf(
                    "transcript_id",
                    "raw_text",
                    "legacy_text",
                    "updated_at_millis",
                ),
                "transcript_id LIKE ?",
                arrayOf("%.conversation"),
                null,
                null,
                null,
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    val transcriptId = cursor.getString(0)
                    val conversationId =
                        transcriptId.removeSuffix(".conversation")
                    if (conversationId.isEmpty() ||
                        hasExactConversationTurns(this, conversationId)
                    ) {
                        continue
                    }
                    delete(
                        TABLE_CONVERSATIONS,
                        "conversation_id = ? AND speaker_id LIKE ?",
                        arrayOf(
                            conversationId,
                            "$RECOVERED_SPEAKER_PREFIX%",
                        ),
                    )
                    val text =
                        if (!cursor.isNull(1)) {
                            cursor.getString(1)
                        } else if (!cursor.isNull(2)) {
                            cursor.getString(2)
                        } else {
                            ""
                        }
                    val updatedAtMillis = cursor.getLong(3)
                    for ((index, turn) in parseSharedConversation(text)
                        .withIndex()) {
                        val speakerKey =
                            turn.speakerLabel
                                .lowercase()
                                .replace(Regex("[^a-z0-9]+"), "_")
                                .trim('_')
                                .ifEmpty { "speaker" }
                        insertWithOnConflict(
                            TABLE_CONVERSATIONS,
                            null,
                            ContentValues().apply {
                                put(
                                    "turn_id",
                                    "$conversationId-shared-${index + 1}",
                                )
                                put("conversation_id", conversationId)
                                put(
                                    "speaker_id",
                                    "$RECOVERED_SPEAKER_PREFIX$speakerKey",
                                )
                                put("speaker_label", turn.speakerLabel)
                                put(
                                    "turn_text",
                                    turn.text.take(MAX_TEXT_CHARACTERS),
                                )
                                put("start_ms", turn.startMs)
                                put("end_ms", turn.endMs)
                                put("confidence", 0.0)
                                put(
                                    "is_primary",
                                    if (turn.speakerLabel == "You") 1 else 0,
                                )
                                put(
                                    "is_overlap",
                                    if (turn.speakerLabel ==
                                        "Overlapping speakers"
                                    ) {
                                        1
                                    } else {
                                        0
                                    },
                                )
                                put("updated_at_millis", updatedAtMillis)
                            },
                            SQLiteDatabase.CONFLICT_REPLACE,
                        )
                        recovered++
                    }
                }
            }
        }
        return recovered
    }

    @Synchronized
    fun replaceMessages(entries: List<Map<String, Any?>>) {
        writableDatabase.runInTransaction {
            delete(TABLE_MESSAGES, null, null)
            for (entry in entries) {
                val id = (entry["id"] as? String)?.trim().orEmpty()
                val direction = entry["direction"] as? String
                val text = (entry["text"] as? String)?.trim().orEmpty()
                val updatedAtMillis =
                    (entry["updatedAtMillis"] as? Number)?.toLong()
                if (id.isEmpty() ||
                    direction !in setOf("sent", "received") ||
                    text.isEmpty() ||
                    updatedAtMillis == null
                ) {
                    continue
                }
                val values =
                    ContentValues().apply {
                        put("message_id", id)
                        put("direction", direction)
                        put("message_text", text)
                        put("updated_at_millis", updatedAtMillis)
                    }
                insertWithOnConflict(
                    TABLE_MESSAGES,
                    null,
                    values,
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            markSnapshot(this, META_MESSAGES_SNAPSHOT)
        }
    }

    @Synchronized
    fun listTranscripts(): List<Map<String, Any?>> {
        val entries = mutableListOf<Map<String, Any?>>()
        readableDatabase.query(
            TABLE_TRANSCRIPTS,
            arrayOf(
                "transcript_id",
                "raw_text",
                "legacy_text",
                "corrected_text",
                "audio_file_name",
                "updated_at_millis",
            ),
            "raw_text IS NOT NULL OR legacy_text IS NOT NULL",
            null,
            null,
            null,
            "updated_at_millis DESC, transcript_id DESC",
            MAX_VISIBLE_TRANSCRIPTS.toString(),
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val rawText = cursor.nullableString(1)
                val legacyText = cursor.nullableString(2)
                entries.add(
                    mapOf(
                        "id" to cursor.getString(0),
                        "originalText" to (rawText ?: legacyText),
                        "correctedText" to cursor.nullableString(3),
                        "audioFileName" to cursor.nullableString(4),
                        "updatedAtMillis" to cursor.getLong(5),
                    ),
                )
            }
        }
        return entries
    }

    @Synchronized
    fun listMessages(): List<Map<String, Any?>> {
        val entries = mutableListOf<Map<String, Any?>>()
        readableDatabase.query(
            TABLE_MESSAGES,
            arrayOf(
                "message_id",
                "direction",
                "message_text",
                "updated_at_millis",
            ),
            null,
            null,
            null,
            null,
            "updated_at_millis DESC, message_id DESC",
            MAX_VISIBLE_MESSAGES.toString(),
        ).use { cursor ->
            while (cursor.moveToNext()) {
                entries.add(
                    mapOf(
                        "id" to cursor.getString(0),
                        "direction" to cursor.getString(1),
                        "text" to cursor.getString(2),
                        "updatedAtMillis" to cursor.getLong(3),
                    ),
                )
            }
        }
        return entries
    }

    @Synchronized
    fun suggestAgentNamesFromMessages(): List<String> {
        data class Candidate(var count: Int = 0, var newest: Long = 0)

        val candidates = mutableMapOf<String, Candidate>()
        val labels = mutableMapOf<String, String>()
        val prefix = Regex("^\\s*([A-Za-z][A-Za-z0-9 _-]{0,63}):(?:\\s|$)")
        readableDatabase.query(
            TABLE_MESSAGES,
            arrayOf("message_text", "updated_at_millis"),
            "direction = ?",
            arrayOf("received"),
            null,
            null,
            null,
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val match = prefix.find(cursor.getString(0)) ?: continue
                val label = match.groupValues[1].trim()
                val key = label.lowercase()
                val candidate = candidates.getOrPut(key) { Candidate() }
                candidate.count++
                candidate.newest = maxOf(candidate.newest, cursor.getLong(1))
                labels.putIfAbsent(key, label)
            }
        }
        return candidates.entries
            .sortedWith(
                compareByDescending<Map.Entry<String, Candidate>> {
                    it.value.count
                }.thenByDescending { it.value.newest }
                    .thenBy { it.key },
            ).take(4)
            .mapNotNull { labels[it.key] }
    }

    @Synchronized
    fun replaceConversationTurns(entries: List<Map<String, Any?>>) {
        val conversationIds =
            entries
                .mapNotNull { (it["conversationId"] as? String)?.trim() }
                .filter { it.isNotEmpty() }
                .toSet()
        if (conversationIds.isEmpty()) {
            return
        }
        writableDatabase.runInTransaction {
            for (conversationId in conversationIds) {
                delete(
                    TABLE_CONVERSATIONS,
                    "conversation_id = ?",
                    arrayOf(conversationId),
                )
            }
            for (entry in entries) {
                val id = (entry["id"] as? String)?.trim().orEmpty()
                val conversationId =
                    (entry["conversationId"] as? String)?.trim().orEmpty()
                val speakerId =
                    (entry["speakerId"] as? String)?.trim().orEmpty()
                val speakerLabel =
                    (entry["speakerLabel"] as? String)?.trim().orEmpty()
                val text = (entry["text"] as? String)?.trim().orEmpty()
                val startMs = (entry["startMs"] as? Number)?.toLong()
                val endMs = (entry["endMs"] as? Number)?.toLong()
                val confidence =
                    (entry["confidence"] as? Number)?.toDouble()
                val updatedAtMillis =
                    (entry["updatedAtMillis"] as? Number)?.toLong()
                if (id.isEmpty() ||
                    conversationId.isEmpty() ||
                    speakerId.isEmpty() ||
                    speakerLabel.isEmpty() ||
                    text.isEmpty() ||
                    startMs == null ||
                    endMs == null ||
                    endMs <= startMs ||
                    confidence == null ||
                    !confidence.isFinite() ||
                    updatedAtMillis == null
                ) {
                    continue
                }
                insertWithOnConflict(
                    TABLE_CONVERSATIONS,
                    null,
                    ContentValues().apply {
                        put("turn_id", id)
                        put("conversation_id", conversationId)
                        put("speaker_id", speakerId)
                        put("speaker_label", speakerLabel)
                        put("turn_text", text.take(MAX_TEXT_CHARACTERS))
                        put("start_ms", startMs)
                        put("end_ms", endMs)
                        put("confidence", confidence.coerceIn(0.0, 1.0))
                        put(
                            "is_primary",
                            if (entry["isPrimary"] == true) 1 else 0,
                        )
                        put(
                            "is_overlap",
                            if (entry["isOverlap"] == true) 1 else 0,
                        )
                        put("updated_at_millis", updatedAtMillis)
                    },
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
        }
    }

    @Synchronized
    fun listConversationTurns(): List<Map<String, Any?>> {
        val entries = mutableListOf<Map<String, Any?>>()
        readableDatabase.query(
            TABLE_CONVERSATIONS,
            arrayOf(
                "turn_id",
                "conversation_id",
                "speaker_id",
                "speaker_label",
                "turn_text",
                "start_ms",
                "end_ms",
                "confidence",
                "is_primary",
                "is_overlap",
                "updated_at_millis",
            ),
            null,
            null,
            null,
            null,
            "updated_at_millis DESC, conversation_id DESC, start_ms DESC",
            MAX_VISIBLE_CONVERSATION_TURNS.toString(),
        ).use { cursor ->
            while (cursor.moveToNext()) {
                entries.add(
                    mapOf(
                        "id" to cursor.getString(0),
                        "conversationId" to cursor.getString(1),
                        "speakerId" to cursor.getString(2),
                        "speakerLabel" to cursor.getString(3),
                        "text" to cursor.getString(4),
                        "startMs" to cursor.getLong(5),
                        "endMs" to cursor.getLong(6),
                        "confidence" to cursor.getDouble(7),
                        "isPrimary" to (cursor.getInt(8) == 1),
                        "isOverlap" to (cursor.getInt(9) == 1),
                        "updatedAtMillis" to cursor.getLong(10),
                    ),
                )
            }
        }
        entries.reverse()
        return entries
    }

    @Synchronized
    fun indexExportedFile(source: File) {
        val classified = classify(source.name) ?: return
        val modifiedAt =
            source.lastModified().takeIf { it > 0 } ?: System.currentTimeMillis()
        val database = writableDatabase
        when (classified.kind) {
            SharedHistoryFileKind.sentMessage,
            SharedHistoryFileKind.receivedMessage,
            -> {
                val text = readText(source)
                if (text.isEmpty()) {
                    return
                }
                val direction =
                    if (classified.kind == SharedHistoryFileKind.sentMessage) {
                        "sent"
                    } else {
                        "received"
                    }
                val values =
                    ContentValues().apply {
                        put("message_id", source.name)
                        put("direction", direction)
                        put("message_text", text)
                        put("updated_at_millis", modifiedAt)
                    }
                database.insertWithOnConflict(
                    TABLE_MESSAGES,
                    null,
                    values,
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            SharedHistoryFileKind.rawTranscript,
            SharedHistoryFileKind.legacyTranscript,
            SharedHistoryFileKind.correctedTranscript,
            SharedHistoryFileKind.audio,
            -> {
                database.insertWithOnConflict(
                    TABLE_TRANSCRIPTS,
                    null,
                    ContentValues().apply {
                        put("transcript_id", classified.id)
                        put("updated_at_millis", 0L)
                    },
                    SQLiteDatabase.CONFLICT_IGNORE,
                )
                val column =
                    when (classified.kind) {
                        SharedHistoryFileKind.rawTranscript -> "raw_text"
                        SharedHistoryFileKind.legacyTranscript -> "legacy_text"
                        SharedHistoryFileKind.correctedTranscript ->
                            "corrected_text"
                        SharedHistoryFileKind.audio -> "audio_file_name"
                        else -> error("Unexpected history file kind.")
                    }
                val value =
                    if (classified.kind == SharedHistoryFileKind.audio) {
                        source.name
                    } else {
                        readText(source)
                    }
                if (value.isEmpty()) {
                    return
                }
                database.execSQL(
                    """
                    UPDATE $TABLE_TRANSCRIPTS
                    SET $column = ?,
                        updated_at_millis = MAX(updated_at_millis, ?)
                    WHERE transcript_id = ?
                    """.trimIndent(),
                    arrayOf(value, modifiedAt, classified.id),
                )
            }
        }
    }

    @Synchronized
    fun isCurrentExport(source: File): Boolean {
        readableDatabase.query(
            TABLE_EXPORTS,
            arrayOf("file_size", "modified_at_millis"),
            "file_name = ?",
            arrayOf(source.name),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            return cursor.moveToFirst() &&
                cursor.getLong(0) == source.length() &&
                cursor.getLong(1) == source.lastModified()
        }
    }

    @Synchronized
    fun hasExportRecord(fileName: String): Boolean {
        readableDatabase.query(
            TABLE_EXPORTS,
            arrayOf("file_name"),
            "file_name = ?",
            arrayOf(fileName),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            return cursor.moveToFirst()
        }
    }

    @Synchronized
    fun markExported(source: File) {
        writableDatabase.insertWithOnConflict(
            TABLE_EXPORTS,
            null,
            ContentValues().apply {
                put("file_name", source.name)
                put("file_size", source.length())
                put("modified_at_millis", source.lastModified())
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    /**
     * Writes a self-contained recovery database without exposing the live
     * SQLite file to a document provider. Export fingerprints and cache-only
     * metadata stay app-private; only reconstructable history rows are copied.
     */
    @Synchronized
    fun writeRecoverySnapshot(target: File): SharedHistorySnapshotCounts {
        target.parentFile?.let { parent ->
            check(parent.isDirectory || parent.mkdirs()) {
                "Could not create the recovery snapshot directory."
            }
        }
        val partial = File("${target.path}.part")
        if (partial.exists() && !partial.delete()) {
            throw IllegalStateException("Could not replace a partial snapshot.")
        }
        val snapshot = SQLiteDatabase.openOrCreateDatabase(partial, null)
        val counts: SharedHistorySnapshotCounts
        try {
            createRecoverySnapshotTables(snapshot)
            snapshot.version = RECOVERY_SNAPSHOT_VERSION
            snapshot.beginTransaction()
            try {
                counts =
                    SharedHistorySnapshotCounts(
                        transcripts =
                            copyTable(
                                source = readableDatabase,
                                target = snapshot,
                                table = TABLE_TRANSCRIPTS,
                                columns = TRANSCRIPT_COLUMNS,
                            ),
                        messages =
                            copyTable(
                                source = readableDatabase,
                                target = snapshot,
                                table = TABLE_MESSAGES,
                                columns = MESSAGE_COLUMNS,
                            ),
                        conversationTurns =
                            copyTable(
                                source = readableDatabase,
                                target = snapshot,
                                table = TABLE_CONVERSATIONS,
                                columns = CONVERSATION_COLUMNS,
                            ),
                    )
                snapshot.setTransactionSuccessful()
            } finally {
                snapshot.endTransaction()
            }
            requireHealthyRecoverySnapshot(snapshot)
        } finally {
            snapshot.close()
        }
        if (target.exists() && !target.delete()) {
            partial.delete()
            throw IllegalStateException("Could not replace the recovery snapshot.")
        }
        if (!partial.renameTo(target)) {
            partial.delete()
            throw IllegalStateException("Could not publish the recovery snapshot.")
        }
        return counts
    }

    /** Merges a validated recovery snapshot into the app-private cache. */
    @Synchronized
    fun restoreRecoverySnapshot(source: File): SharedHistorySnapshotCounts {
        require(source.isFile && source.length() in 1..MAX_RECOVERY_SNAPSHOT_BYTES) {
            "The recovery snapshot has an invalid size."
        }
        val snapshot =
            SQLiteDatabase.openDatabase(
                source.path,
                null,
                SQLiteDatabase.OPEN_READONLY,
            )
        try {
            requireHealthyRecoverySnapshot(snapshot)
            val counts =
                SharedHistorySnapshotCounts(
                    transcripts = countRows(snapshot, TABLE_TRANSCRIPTS),
                    messages = countRows(snapshot, TABLE_MESSAGES),
                    conversationTurns = countRows(snapshot, TABLE_CONVERSATIONS),
                )
            writableDatabase.runInTransaction {
                copyTable(
                    source = snapshot,
                    target = this,
                    table = TABLE_TRANSCRIPTS,
                    columns = TRANSCRIPT_COLUMNS,
                )
                copyTable(
                    source = snapshot,
                    target = this,
                    table = TABLE_MESSAGES,
                    columns = MESSAGE_COLUMNS,
                )
                copyTable(
                    source = snapshot,
                    target = this,
                    table = TABLE_CONVERSATIONS,
                    columns = CONVERSATION_COLUMNS,
                )
                markSnapshot(this, META_TRANSCRIPTS_SNAPSHOT)
                markSnapshot(this, META_MESSAGES_SNAPSHOT)
            }
            return counts
        } finally {
            snapshot.close()
        }
    }

    private fun createRecoverySnapshotTables(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE $TABLE_TRANSCRIPTS (
                transcript_id TEXT PRIMARY KEY NOT NULL,
                raw_text TEXT,
                legacy_text TEXT,
                corrected_text TEXT,
                audio_file_name TEXT,
                updated_at_millis INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        database.execSQL(
            """
            CREATE TABLE $TABLE_MESSAGES (
                message_id TEXT PRIMARY KEY NOT NULL,
                direction TEXT NOT NULL,
                message_text TEXT NOT NULL,
                updated_at_millis INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        createConversationTable(database)
    }

    private fun requireHealthyRecoverySnapshot(database: SQLiteDatabase) {
        require(database.version == RECOVERY_SNAPSHOT_VERSION) {
            "Unsupported recovery snapshot version."
        }
        database.rawQuery("PRAGMA quick_check(1)", null).use { cursor ->
            require(cursor.moveToFirst() && cursor.getString(0) == "ok") {
                "Recovery snapshot integrity validation failed."
            }
        }
        // Querying every expected column rejects unrelated or incomplete
        // SQLite files before any row reaches the private cache.
        database.query(
            TABLE_TRANSCRIPTS,
            TRANSCRIPT_COLUMNS,
            null,
            null,
            null,
            null,
            null,
            "0",
        ).close()
        database.query(
            TABLE_MESSAGES,
            MESSAGE_COLUMNS,
            null,
            null,
            null,
            null,
            null,
            "0",
        ).close()
        database.query(
            TABLE_CONVERSATIONS,
            CONVERSATION_COLUMNS,
            null,
            null,
            null,
            null,
            null,
            "0",
        ).close()
    }

    private fun copyTable(
        source: SQLiteDatabase,
        target: SQLiteDatabase,
        table: String,
        columns: Array<String>,
    ): Int {
        var copied = 0
        source.query(table, columns, null, null, null, null, null).use { cursor ->
            while (cursor.moveToNext()) {
                val values = ContentValues()
                DatabaseUtils.cursorRowToContentValues(cursor, values)
                target.insertWithOnConflict(
                    table,
                    null,
                    values,
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
                copied++
            }
        }
        return copied
    }

    private fun countRows(
        database: SQLiteDatabase,
        table: String,
    ): Int =
        DatabaseUtils.queryNumEntries(database, table)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()

    private fun hasSnapshot(key: String): Boolean {
        readableDatabase.query(
            TABLE_META,
            arrayOf("cache_value"),
            "cache_key = ?",
            arrayOf(key),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            return cursor.moveToFirst() && cursor.getInt(0) == 1
        }
    }

    private fun hasExactConversationTurns(
        database: SQLiteDatabase,
        conversationId: String,
    ): Boolean {
        database.query(
            TABLE_CONVERSATIONS,
            arrayOf("turn_id"),
            "conversation_id = ? AND speaker_id NOT LIKE ?",
            arrayOf(conversationId, "$RECOVERED_SPEAKER_PREFIX%"),
            null,
            null,
            null,
            "1",
        ).use { cursor ->
            return cursor.moveToFirst()
        }
    }

    private fun parseSharedConversation(
        value: String,
    ): List<RecoveredConversationTurn> {
        val turns = mutableListOf<RecoveredConversationTurn>()
        val blocks = value.replace("\r\n", "\n").trim().split(Regex("\n{2,}"))
        val header =
            Regex(
                "^(.+?) \\[([0-9]+(?:\\.[0-9]+)?)\\s*[–-]\\s*" +
                    "([0-9]+(?:\\.[0-9]+)?)\\]$",
            )
        for (block in blocks) {
            val lines = block.lines()
            if (lines.size < 2) {
                continue
            }
            val match = header.matchEntire(lines.first().trim()) ?: continue
            val speakerLabel = match.groupValues[1].trim()
            val startMs =
                (match.groupValues[2].toDoubleOrNull()?.times(1000.0))
                    ?.toLong()
            val endMs =
                (match.groupValues[3].toDoubleOrNull()?.times(1000.0))
                    ?.toLong()
            val text = lines.drop(1).joinToString("\n").trim()
            if (speakerLabel.isEmpty() ||
                startMs == null ||
                endMs == null ||
                endMs <= startMs ||
                text.isEmpty()
            ) {
                continue
            }
            turns.add(
                RecoveredConversationTurn(
                    speakerLabel = speakerLabel,
                    text = text,
                    startMs = startMs,
                    endMs = endMs,
                ),
            )
        }
        return turns
    }

    private fun createConversationTable(database: SQLiteDatabase) {
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $TABLE_CONVERSATIONS (
                turn_id TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL,
                speaker_id TEXT NOT NULL,
                speaker_label TEXT NOT NULL,
                turn_text TEXT NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                confidence REAL NOT NULL,
                is_primary INTEGER NOT NULL,
                is_overlap INTEGER NOT NULL,
                updated_at_millis INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        database.execSQL(
            "CREATE INDEX IF NOT EXISTS conversation_updated_idx " +
                "ON $TABLE_CONVERSATIONS(updated_at_millis ASC, " +
                "conversation_id ASC, start_ms ASC)",
        )
    }

    private fun markSnapshot(
        database: SQLiteDatabase,
        key: String,
    ) {
        database.insertWithOnConflict(
            TABLE_META,
            null,
            ContentValues().apply {
                put("cache_key", key)
                put("cache_value", 1)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    private fun classify(name: String): SharedHistoryFile? {
        val lower = name.lowercase()
        if (name.isEmpty() ||
            lower == MainActivity.CORRECTION_PROMPT_FILE_NAME ||
            lower.endsWith(".part.wav") ||
            lower.endsWith(".part.txt")
        ) {
            return null
        }
        val suffixAndKind =
            when {
                lower.endsWith(".sent.message.txt") ->
                    ".sent.message.txt" to SharedHistoryFileKind.sentMessage
                lower.endsWith(".received.message.txt") ->
                    ".received.message.txt" to
                        SharedHistoryFileKind.receivedMessage
                lower.endsWith(".corrected.txt") ->
                    ".corrected.txt" to
                        SharedHistoryFileKind.correctedTranscript
                lower.endsWith(".raw.txt") ->
                    ".raw.txt" to SharedHistoryFileKind.rawTranscript
                lower.endsWith(".txt") ->
                    ".txt" to SharedHistoryFileKind.legacyTranscript
                lower.endsWith(".wav") -> ".wav" to SharedHistoryFileKind.audio
                else -> return null
            }
        val id =
            if (suffixAndKind.second in
                setOf(
                    SharedHistoryFileKind.sentMessage,
                    SharedHistoryFileKind.receivedMessage,
                )
            ) {
                name
            } else {
                name.dropLast(suffixAndKind.first.length)
            }
        return id.takeIf { it.isNotEmpty() }?.let {
            SharedHistoryFile(it, suffixAndKind.second)
        }
    }

    private fun readText(source: File): String {
        val output = StringBuilder()
        source.bufferedReader(Charsets.UTF_8).use { reader ->
            val buffer = CharArray(4096)
            while (output.length < MAX_TEXT_CHARACTERS) {
                val remaining =
                    minOf(buffer.size, MAX_TEXT_CHARACTERS - output.length)
                val count = reader.read(buffer, 0, remaining)
                if (count <= 0) {
                    break
                }
                output.append(buffer, 0, count)
            }
        }
        return output.toString().trim()
    }
}

internal data class SharedHistorySnapshotCounts(
    val transcripts: Int,
    val messages: Int,
    val conversationTurns: Int,
)

private data class RecoveredConversationTurn(
    val speakerLabel: String,
    val text: String,
    val startMs: Long,
    val endMs: Long,
)

private data class SharedHistoryFile(
    val id: String,
    val kind: SharedHistoryFileKind,
)

private enum class SharedHistoryFileKind {
    rawTranscript,
    legacyTranscript,
    correctedTranscript,
    audio,
    sentMessage,
    receivedMessage,
}

private fun ContentValues.putNullableText(
    key: String,
    value: String?,
) {
    val trimmed = value?.trim().orEmpty()
    if (trimmed.isEmpty()) {
        putNull(key)
    } else {
        put(key, trimmed)
    }
}

private fun android.database.Cursor.nullableString(index: Int): String? =
    if (isNull(index)) null else getString(index)

private inline fun <T> SQLiteDatabase.runInTransaction(
    block: SQLiteDatabase.() -> T,
): T {
    beginTransaction()
    return try {
        val value = block()
        setTransactionSuccessful()
        value
    } finally {
        endTransaction()
    }
}
