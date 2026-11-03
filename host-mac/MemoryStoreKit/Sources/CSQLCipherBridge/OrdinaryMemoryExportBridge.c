#include "MemorySQLCipherInternal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static MemorySQLCipherStatus export_status(int code) {
    if (code == SQLITE_OK || code == SQLITE_DONE) return MemorySQLCipherStatusOK;
    if (code == SQLITE_NOMEM) return MemorySQLCipherStatusOutOfMemory;
    return MemorySQLCipherStatusDatabaseError;
}

static int equals_literal(const char *value, size_t length, const char *literal) {
    size_t expected = strlen(literal);
    return length == expected && memcmp(value, literal, length) == 0;
}

static char *copy_text(sqlite3_stmt *statement, int column, size_t maximumBytes,
                       size_t *lengthOut) {
    const unsigned char *value = sqlite3_column_text(statement, column);
    int length = sqlite3_column_bytes(statement, column);
    if (value == NULL || length <= 0 || (size_t)length > maximumBytes
        || memchr(value, 0, (size_t)length) != NULL) return NULL;
    char *copy = malloc((size_t)length + 1);
    if (copy == NULL) return NULL;
    memcpy(copy, value, (size_t)length);
    copy[length] = '\0';
    *lengthOut = (size_t)length;
    return copy;
}

void memory_sqlcipher_free_export_rows(MemorySQLCipherExportRow *rows, size_t count) {
    if (rows == NULL) return;
    for (size_t index = 0; index < count; index++) {
        free(rows[index].identifier);
        free(rows[index].recordType);
        free(rows[index].body);
        free(rows[index].source);
    }
    free(rows);
}

MemorySQLCipherStatus memory_sqlcipher_export_rows(MemorySQLCipherStore *store,
    int limit, size_t maximumBodyBytes, size_t maximumTotalBytes,
    MemorySQLCipherExportRow **rowsOut, size_t *countOut) {
    if (store == NULL || store->database == NULL || rowsOut == NULL || countOut == NULL
        || limit < 1 || limit > 501 || maximumBodyBytes < 1 || maximumBodyBytes > 1048576
        || maximumTotalBytes < 1 || maximumTotalBytes > 1048576) {
        return MemorySQLCipherStatusInvalidArgument;
    }
    *rowsOut = NULL;
    *countOut = 0;
    const char *sql = "SELECT id,kind,body,source,observed_at,status,confidence "
        "FROM memory_items WHERE kind IN ('profile','fact') ORDER BY id COLLATE BINARY LIMIT ?;";
    sqlite3_stmt *statement = NULL;
    int code = sqlite3_prepare_v2(store->database, sql, -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_int(statement, 1, limit);
    if (code != SQLITE_OK) {
        sqlite3_finalize(statement);
        return export_status(code);
    }
    MemorySQLCipherExportRow *rows = calloc((size_t)limit, sizeof(*rows));
    if (rows == NULL) { sqlite3_finalize(statement); return MemorySQLCipherStatusOutOfMemory; }
    size_t count = 0, totalBytes = 0;
    while ((code = sqlite3_step(statement)) == SQLITE_ROW) {
        if (count >= (size_t)limit) { code = SQLITE_TOOBIG; break; }
        if (sqlite3_column_type(statement, 0) != SQLITE_TEXT
            || sqlite3_column_type(statement, 1) != SQLITE_TEXT
            || sqlite3_column_type(statement, 2) != SQLITE_TEXT
            || sqlite3_column_type(statement, 3) != SQLITE_TEXT
            || sqlite3_column_type(statement, 4) != SQLITE_INTEGER
            || sqlite3_column_type(statement, 5) != SQLITE_INTEGER
            || (sqlite3_column_type(statement, 6) != SQLITE_FLOAT
                && sqlite3_column_type(statement, 6) != SQLITE_INTEGER)) {
            code = SQLITE_ERROR; count++; break;
        }
        MemorySQLCipherExportRow *row = &rows[count];
        size_t idLength = 0, kindLength = 0, bodyLength = 0, sourceLength = 0;
        row->identifier = copy_text(statement, 0, 512, &idLength);
        row->recordType = copy_text(statement, 1, 16, &kindLength);
        row->source = copy_text(statement, 3, 32, &sourceLength);
        if (row->identifier == NULL || row->recordType == NULL || row->source == NULL
            || (!equals_literal(row->recordType, kindLength, "profile")
                && !equals_literal(row->recordType, kindLength, "fact"))
            || (!equals_literal(row->source, sourceLength, "owner_message")
                && !equals_literal(row->source, sourceLength, "owner_confirmed"))) {
            code = SQLITE_ERROR; count++; break;
        }
        size_t overhead = idLength + kindLength + sourceLength + 64;
        if (overhead > maximumTotalBytes - totalBytes) { code = SQLITE_TOOBIG; count++; break; }
        size_t remaining = maximumTotalBytes - totalBytes - overhead;
        row->body = copy_text(statement, 2,
            remaining < maximumBodyBytes ? remaining : maximumBodyBytes, &bodyLength);
        if (row->body == NULL) {
            int bytes = sqlite3_column_bytes(statement, 2);
            code = bytes > (int)(remaining < maximumBodyBytes ? remaining : maximumBodyBytes)
                ? SQLITE_TOOBIG : SQLITE_ERROR;
            count++; break;
        }
        row->observedAt = sqlite3_column_int64(statement, 4);
        row->status = sqlite3_column_int(statement, 5);
        row->confidence = sqlite3_column_double(statement, 6);
        if ((row->status != 0 && row->status != 1) || !isfinite(row->confidence)
            || row->confidence < 0.0 || row->confidence > 1.0) {
            code = SQLITE_ERROR; count++; break;
        }
        totalBytes += overhead + bodyLength;
        count++;
    }
    sqlite3_finalize(statement);
    if (code != SQLITE_DONE) {
        memory_sqlcipher_free_export_rows(rows, count);
        return export_status(code);
    }
    *rowsOut = rows;
    *countOut = count;
    return MemorySQLCipherStatusOK;
}
