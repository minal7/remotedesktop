#include "MemorySQLCipherInternal.h"
#include <stdlib.h>
#include <string.h>

static int valid_bytes(const uint8_t *bytes, size_t length) {
    if (bytes == NULL || length == 0 || length > 256) return 0;
    return memchr(bytes, 0, length) == NULL;
}

static MemorySQLCipherStatus approval_status(int code) {
    if (code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW) return MemorySQLCipherStatusOK;
    if (code == SQLITE_NOMEM) return MemorySQLCipherStatusOutOfMemory;
    if (code == SQLITE_CONSTRAINT) return MemorySQLCipherStatusConflict;
    return MemorySQLCipherStatusDatabaseError;
}

MemorySQLCipherStatus memory_sqlcipher_enroll_vault_approval_key(MemorySQLCipherStore *store,
                                                                  const uint8_t *owner, size_t ownerLength,
                                                                  const uint8_t *peer, size_t peerLength,
                                                                  const uint8_t *key, size_t keyLength) {
    if (store == NULL || store->database == NULL || !valid_bytes(owner, ownerLength)
        || !valid_bytes(peer, peerLength) || key == NULL || keyLength != 65)
        return MemorySQLCipherStatusInvalidArgument;
    sqlite3 *db = store->database;
    int code = sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    sqlite3_stmt *query = NULL;
    if (code == SQLITE_OK) code = sqlite3_prepare_v2(db,
        "SELECT public_key FROM vault_approval_keys WHERE owner_id=?1 AND peer_id=?2;", -1, &query, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(query, 1, (const char *)owner, (int)ownerLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(query, 2, (const char *)peer, (int)peerLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(query);
    if (code == SQLITE_ROW) {
        const void *existing = sqlite3_column_blob(query, 0);
        int existingLength = sqlite3_column_bytes(query, 0);
        int equal = sqlite3_column_type(query, 0) == SQLITE_BLOB && existingLength == 65
            && existing != NULL && memcmp(existing, key, 65) == 0;
        sqlite3_finalize(query);
        query = NULL;
        if (equal) {
            code = sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
            if (code != SQLITE_OK) sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
            return approval_status(code);
        }
        sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
        return MemorySQLCipherStatusConflict;
    }
    sqlite3_finalize(query);
    if (code != SQLITE_DONE) {
        sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
        return approval_status(code);
    }
    sqlite3_stmt *insert = NULL;
    code = sqlite3_prepare_v2(db,
        "INSERT INTO vault_approval_keys(owner_id,peer_id,public_key) VALUES(?1,?2,?3);", -1, &insert, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(insert, 1, (const char *)owner, (int)ownerLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(insert, 2, (const char *)peer, (int)peerLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_blob(insert, 3, key, (int)keyLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(insert);
    sqlite3_finalize(insert);
    if (code == SQLITE_DONE) code = sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    if (code != SQLITE_OK) sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
    return approval_status(code);
}

MemorySQLCipherStatus memory_sqlcipher_get_vault_approval_key(MemorySQLCipherStore *store,
                                                               const uint8_t *owner, size_t ownerLength,
                                                               const uint8_t *peer, size_t peerLength,
                                                               uint8_t **keyOut, size_t *keyLengthOut) {
    if (store == NULL || store->database == NULL || !valid_bytes(owner, ownerLength)
        || !valid_bytes(peer, peerLength) || keyOut == NULL || keyLengthOut == NULL)
        return MemorySQLCipherStatusInvalidArgument;
    *keyOut = NULL;
    *keyLengthOut = 0;
    sqlite3_stmt *statement = NULL;
    int code = sqlite3_prepare_v2(store->database,
        "SELECT public_key FROM vault_approval_keys WHERE owner_id=?1 AND peer_id=?2;", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1, (const char *)owner, (int)ownerLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 2, (const char *)peer, (int)peerLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    if (code == SQLITE_ROW) {
        const void *bytes = sqlite3_column_blob(statement, 0);
        int length = sqlite3_column_bytes(statement, 0);
        if (sqlite3_column_type(statement, 0) != SQLITE_BLOB || bytes == NULL || length != 65) {
            code = SQLITE_CORRUPT;
        } else {
            uint8_t *copy = (uint8_t *)malloc(65);
            if (copy == NULL) code = SQLITE_NOMEM;
            else { memcpy(copy, bytes, 65); *keyOut = copy; *keyLengthOut = 65; code = SQLITE_OK; }
        }
    } else if (code == SQLITE_DONE) {
        code = SQLITE_NOTFOUND;
    }
    sqlite3_finalize(statement);
    if (code == SQLITE_NOTFOUND) return MemorySQLCipherStatusNotFound;
    return approval_status(code);
}
