#include "MemorySQLCipherInternal.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const uint8_t *bytes;
    size_t length;
} EditField;

typedef struct {
    EditField fields[10];
    int64_t observedAt;
    int status;
    double confidence;
} EditRecord;

static MemorySQLCipherStatus edit_status(int code) {
    if (code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW) return MemorySQLCipherStatusOK;
    if (code == SQLITE_NOMEM) return MemorySQLCipherStatusOutOfMemory;
    return MemorySQLCipherStatusDatabaseError;
}

static int edit_exec(sqlite3 *db, const char *sql) {
    char *message = NULL;
    int code = sqlite3_exec(db, sql, NULL, NULL, &message);
    if (message != NULL) sqlite3_free(message);
    return code;
}

static uint32_t read_u32_be(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16)
        | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static uint64_t read_u64_be(const uint8_t *bytes) {
    uint64_t value = 0;
    for (size_t index = 0; index < 8; index++) value = (value << 8) | bytes[index];
    return value;
}

static int parse_edit_record(const uint8_t *bytes, size_t length, EditRecord *record) {
    if (bytes == NULL || record == NULL) return 0;
    memset(record, 0, sizeof(*record));
    size_t offset = 0;
    for (size_t index = 0; index < 4; index++) {
        if (length - offset < 4) return 0;
        uint32_t fieldLength = read_u32_be(bytes + offset);
        offset += 4;
        if (fieldLength == 0 || fieldLength > length - offset
            || memchr(bytes + offset, 0, fieldLength) != NULL) return 0;
        record->fields[index] = (EditField){ bytes + offset, fieldLength };
        offset += fieldLength;
    }
    if (length - offset < 17) return 0;
    record->observedAt = (int64_t)read_u64_be(bytes + offset);
    offset += 8;
    record->status = bytes[offset++];
    uint64_t confidenceBits = read_u64_be(bytes + offset);
    memcpy(&record->confidence, &confidenceBits, sizeof(confidenceBits));
    offset += 8;
    if (record->status < 0 || record->status > 1 || !isfinite(record->confidence)
        || record->confidence < 0.0 || record->confidence > 1.0) return 0;
    for (size_t index = 4; index < 10; index++) {
        if (length - offset < 4) return 0;
        uint32_t fieldLength = read_u32_be(bytes + offset);
        offset += 4;
        if (fieldLength > length - offset || memchr(bytes + offset, 0, fieldLength) != NULL) return 0;
        record->fields[index] = (EditField){ fieldLength == 0 ? NULL : bytes + offset, fieldLength };
        offset += fieldLength;
    }
    return offset == length;
}

static int field_equals_column(EditField field, sqlite3_stmt *query, int column) {
    if (field.length == 0) return sqlite3_column_type(query, column) == SQLITE_NULL;
    if (sqlite3_column_type(query, column) == SQLITE_NULL) return 0;
    const void *value = sqlite3_column_text(query, column);
    int length = sqlite3_column_bytes(query, column);
    return value != NULL && length >= 0 && (size_t)length == field.length
        && memcmp(value, field.bytes, field.length) == 0;
}

static int bind_field(sqlite3_stmt *statement, int index, EditField field) {
    return field.length == 0 ? sqlite3_bind_null(statement, index)
        : sqlite3_bind_text(statement, index, (const char *)field.bytes, (int)field.length, SQLITE_TRANSIENT);
}

static char *copy_field(EditField field) {
    if (field.length > SIZE_MAX - 1) return NULL;
    char *copy = (char *)malloc(field.length + 1);
    if (copy == NULL) return NULL;
    memcpy(copy, field.bytes, field.length);
    copy[field.length] = '\0';
    return copy;
}

MemorySQLCipherStatus memory_sqlcipher_edit_owner_record(MemorySQLCipherStore *store,
                                                         const uint8_t *commandBytes, size_t commandLength,
                                                         const uint8_t *digestBytes, size_t digestLength,
                                                         const uint8_t *expectedBytes, size_t expectedLength,
                                                         int revisionMatches,
                                                         const uint8_t *replacementBytes, size_t replacementLength,
                                                         char **recordIDOut, int *idempotentOut) {
    if (store == NULL || store->database == NULL || recordIDOut == NULL || idempotentOut == NULL
        || commandBytes == NULL || commandLength == 0 || commandLength > 1024
        || memchr(commandBytes, 0, commandLength) != NULL || digestBytes == NULL || digestLength != 32) {
        return MemorySQLCipherStatusInvalidArgument;
    }
    EditRecord expected, replacement;
    if ((revisionMatches != 0 && revisionMatches != 1)
        || (expectedLength > 0 && !parse_edit_record(expectedBytes, expectedLength, &expected))
        || (expectedLength > 0 && (expected.fields[0].length > 512 || expected.fields[1].length > 32
            || expected.fields[2].length > 32768 || expected.fields[3].length > 32))
        || (expectedLength == 0 && revisionMatches != 0)
        || !parse_edit_record(replacementBytes, replacementLength, &replacement)
        || replacement.fields[2].length > 4096 || replacement.fields[3].length != 13
        || memcmp(replacement.fields[3].bytes, "owner_message", 13) != 0
        || replacement.fields[6].length == 0
        || replacement.fields[4].length || replacement.fields[5].length
        || replacement.fields[7].length || replacement.fields[8].length || replacement.fields[9].length) {
        return MemorySQLCipherStatusInvalidArgument;
    }
    if (replacement.fields[0].length > 512 || replacement.fields[1].length > 32
        || replacement.fields[2].length == 0 || replacement.fields[6].length > 512) {
        return MemorySQLCipherStatusInvalidArgument;
    }
    const size_t optionalLimits[] = {512, 512, 512, 32, 1024, 1024};
    for (size_t index = 0; index < 6; index++) {
        if (expectedLength > 0 && expected.fields[index + 4].length > optionalLimits[index])
            return MemorySQLCipherStatusInvalidArgument;
    }
    if (expectedLength > 0 && (expected.fields[0].length != replacement.fields[0].length
        || memcmp(expected.fields[0].bytes, replacement.fields[0].bytes, expected.fields[0].length) != 0
        || expected.fields[1].length != replacement.fields[1].length
        || memcmp(expected.fields[1].bytes, replacement.fields[1].bytes, expected.fields[1].length) != 0
        || expected.status != replacement.status)) return MemorySQLCipherStatusInvalidArgument;
    EditField *kind = expectedLength > 0 ? &expected.fields[1] : &replacement.fields[1];
    if ((kind->length != 7 || memcmp(kind->bytes, "profile", 7) != 0)
        && (kind->length != 4 || memcmp(kind->bytes, "fact", 4) != 0)) return MemorySQLCipherStatusInvalidArgument;

    *recordIDOut = NULL;
    *idempotentOut = 0;
    sqlite3 *db = store->database;
    int code = sqlite3_busy_timeout(db, 2000);
    if (code != SQLITE_OK) return edit_status(code);
    code = edit_exec(db, "BEGIN IMMEDIATE;");
    if (code != SQLITE_OK) return edit_status(code);

    sqlite3_stmt *lookup = NULL;
    code = sqlite3_prepare_v2(db,
        "SELECT r.payload_digest,r.record_id,EXISTS(SELECT 1 FROM memory_items WHERE id=r.record_id) "
        "FROM owner_command_receipts AS r WHERE r.command_id=?;", -1, &lookup, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(lookup, 1, (const char *)commandBytes, (int)commandLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(lookup);
    if (code == SQLITE_ROW) {
        const void *priorDigest = sqlite3_column_blob(lookup, 0);
        int priorLength = sqlite3_column_bytes(lookup, 0);
        if (sqlite3_column_int(lookup, 2) != 1 || priorDigest == NULL || priorLength != 32
            || memcmp(priorDigest, digestBytes, 32) != 0) {
            sqlite3_finalize(lookup); edit_exec(db, "ROLLBACK;"); return MemorySQLCipherStatusConflict;
        }
        const unsigned char *priorID = sqlite3_column_text(lookup, 1);
        int priorIDLength = sqlite3_column_bytes(lookup, 1);
        if (priorID == NULL || priorIDLength <= 0) {
            sqlite3_finalize(lookup); edit_exec(db, "ROLLBACK;"); return MemorySQLCipherStatusDatabaseError;
        }
        *recordIDOut = (char *)malloc((size_t)priorIDLength + 1);
        if (*recordIDOut == NULL) {
            sqlite3_finalize(lookup); edit_exec(db, "ROLLBACK;"); return MemorySQLCipherStatusOutOfMemory;
        }
        memcpy(*recordIDOut, priorID, (size_t)priorIDLength);
        (*recordIDOut)[priorIDLength] = '\0';
        sqlite3_finalize(lookup);
        code = edit_exec(db, "COMMIT;");
        if (code != SQLITE_OK) { free(*recordIDOut); *recordIDOut = NULL; edit_exec(db, "ROLLBACK;"); return edit_status(code); }
        *idempotentOut = 1;
        return MemorySQLCipherStatusOK;
    }
    sqlite3_finalize(lookup);
    if (code != SQLITE_DONE) { edit_exec(db, "ROLLBACK;"); return edit_status(code); }
    if (expectedLength == 0) { edit_exec(db, "ROLLBACK;"); return MemorySQLCipherStatusNotFound; }
    if (!revisionMatches) { edit_exec(db, "ROLLBACK;"); return MemorySQLCipherStatusConflict; }

    sqlite3_stmt *select = NULL;
    code = sqlite3_prepare_v2(db,
        "SELECT id,kind,body,source,observed_at,status,confidence,source_message_id,proposal_id,statement_id,candidate_origin,source_reference,source_span "
        "FROM memory_items WHERE id=?;", -1, &select, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(select, 1, (const char *)expected.fields[0].bytes,
                                                    (int)expected.fields[0].length, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(select);
    if (code == SQLITE_DONE) { sqlite3_finalize(select); edit_exec(db, "ROLLBACK;"); return MemorySQLCipherStatusNotFound; }
    if (code != SQLITE_ROW) { sqlite3_finalize(select); edit_exec(db, "ROLLBACK;"); return edit_status(code); }
    int matches = 1;
    int columns[] = {0, 1, 2, 3, 7, 8, 9, 10, 11, 12};
    for (int index = 0; index < 10; index++) matches &= field_equals_column(expected.fields[index], select, columns[index]);
    matches &= sqlite3_column_int64(select, 4) == expected.observedAt;
    matches &= sqlite3_column_int(select, 5) == expected.status;
    matches &= sqlite3_column_double(select, 6) == expected.confidence;
    sqlite3_finalize(select);
    if (!matches) { edit_exec(db, "ROLLBACK;"); return MemorySQLCipherStatusConflict; }

    sqlite3_stmt *update = NULL;
    code = sqlite3_prepare_v2(db,
        "UPDATE memory_items SET body=?,source=?,observed_at=?,status=?,confidence=?,source_message_id=?,proposal_id=?,statement_id=?,candidate_origin=?,source_reference=?,source_span=? "
        "WHERE id=? AND kind IN ('profile','fact');", -1, &update, NULL);
    if (code == SQLITE_OK) code = bind_field(update, 1, replacement.fields[2]);
    if (code == SQLITE_OK) code = bind_field(update, 2, replacement.fields[3]);
    if (code == SQLITE_OK) code = sqlite3_bind_int64(update, 3, replacement.observedAt);
    if (code == SQLITE_OK) code = sqlite3_bind_int(update, 4, replacement.status);
    if (code == SQLITE_OK) code = sqlite3_bind_double(update, 5, replacement.confidence);
    for (int index = 4; code == SQLITE_OK && index < 10; index++) code = bind_field(update, index + 2, replacement.fields[index]);
    if (code == SQLITE_OK) code = bind_field(update, 12, replacement.fields[0]);
    if (code == SQLITE_OK) code = sqlite3_step(update);
    if (code == SQLITE_DONE) code = sqlite3_changes(db) == 1 ? SQLITE_OK : SQLITE_NOTFOUND;
    sqlite3_finalize(update);
    if (code != SQLITE_OK) { edit_exec(db, "ROLLBACK;"); return code == SQLITE_NOTFOUND ? MemorySQLCipherStatusNotFound : edit_status(code); }

    sqlite3_stmt *insert = NULL;
    code = sqlite3_prepare_v2(db,
        "INSERT INTO owner_command_receipts(command_id,payload_digest,record_id) VALUES(?,?,?);", -1, &insert, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(insert, 1, (const char *)commandBytes, (int)commandLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_blob(insert, 2, digestBytes, 32, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = bind_field(insert, 3, replacement.fields[0]);
    if (code == SQLITE_OK) code = sqlite3_step(insert);
    if (code == SQLITE_DONE) code = SQLITE_OK;
    sqlite3_finalize(insert);
    if (code == SQLITE_OK) code = edit_exec(db, "COMMIT;");
    if (code != SQLITE_OK) { edit_exec(db, "ROLLBACK;"); return edit_status(code); }

    *recordIDOut = copy_field(replacement.fields[0]);
    if (*recordIDOut == NULL) return MemorySQLCipherStatusOutOfMemory;
    return MemorySQLCipherStatusOK;
}
