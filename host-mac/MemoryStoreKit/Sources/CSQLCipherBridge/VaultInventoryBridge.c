#include "MemorySQLCipherInternal.h"
#include <stdlib.h>
#include <string.h>

#define VAULT_INVENTORY_LIMIT 1024
#define VAULT_UUID_BYTES 36

static MemorySQLCipherStatus vault_status(int code) {
    if (code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW) return MemorySQLCipherStatusOK;
    if (code == SQLITE_NOMEM) return MemorySQLCipherStatusOutOfMemory;
    if (code == SQLITE_CONSTRAINT) return MemorySQLCipherStatusConflict;
    return MemorySQLCipherStatusDatabaseError;
}

static int valid_uuid(const uint8_t *bytes, size_t length) {
    if (bytes == NULL || length != VAULT_UUID_BYTES) return 0;
    for (size_t i = 0; i < length; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (bytes[i] != '-') return 0;
        } else if (!((bytes[i] >= '0' && bytes[i] <= '9') || (bytes[i] >= 'a' && bytes[i] <= 'f'))) {
            return 0;
        }
    }
    return 1;
}

static int scalar_pending(sqlite3 *db, int *pending) {
    sqlite3_stmt *statement = NULL;
    int code = sqlite3_prepare_v2(db,
        "SELECT vault_erasure_pending FROM memory_lifecycle WHERE singleton=1;", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    if (code == SQLITE_ROW) {
        if (sqlite3_column_type(statement, 0) != SQLITE_INTEGER) {
            sqlite3_finalize(statement);
            return SQLITE_CORRUPT;
        }
        sqlite3_int64 value = sqlite3_column_int64(statement, 0);
        if (value != 0 && value != 1) code = SQLITE_CORRUPT;
        else { *pending = (int)value; code = SQLITE_OK; }
    } else if (code == SQLITE_DONE) {
        code = SQLITE_CORRUPT;
    }
    sqlite3_finalize(statement);
    return code;
}

MemorySQLCipherStatus memory_sqlcipher_create_vault_inventory_schema(MemorySQLCipherStore *store) {
    if (store == NULL || store->database == NULL) return MemorySQLCipherStatusInvalidArgument;
    sqlite3_stmt *versionStatement = NULL;
    int code = sqlite3_prepare_v2(store->database, "PRAGMA user_version;", -1, &versionStatement, NULL);
    if (code == SQLITE_OK) code = sqlite3_step(versionStatement);
    int version = code == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : -1;
    sqlite3_finalize(versionStatement);
    if (version == 4) {
        code = sqlite3_exec(store->database,
            "BEGIN IMMEDIATE;"
            "CREATE TABLE vault_item_inventory(item_id TEXT PRIMARY KEY NOT NULL"
            " CHECK(length(item_id)=36));"
            "CREATE TABLE memory_lifecycle(singleton INTEGER PRIMARY KEY CHECK(singleton=1),"
            "vault_erasure_pending INTEGER NOT NULL CHECK(vault_erasure_pending IN (0,1)));"
            "INSERT INTO memory_lifecycle(singleton,vault_erasure_pending) VALUES(1,0);"
            "PRAGMA user_version=5; COMMIT;", NULL, NULL, NULL);
        if (code != SQLITE_OK) sqlite3_exec(store->database, "ROLLBACK;", NULL, NULL, NULL);
        if (code != SQLITE_OK) return vault_status(code);
        version = 5;
    }
    if (version == 5) {
        code = sqlite3_exec(store->database,
            "BEGIN IMMEDIATE;"
            "CREATE TABLE vault_create_reservations("
            "command_key TEXT PRIMARY KEY NOT NULL CHECK(length(command_key)=64),"
            "owner_id TEXT NOT NULL CHECK(length(owner_id)>0),"
            "item_id TEXT NOT NULL UNIQUE CHECK(length(item_id)=36),"
            "kind TEXT NOT NULL CHECK(kind IN ('paymentCard','address','phone','membership','identity')),"
            "state INTEGER NOT NULL CHECK(state IN (0,1)),"
            "safe_display TEXT,"
            "CHECK((state=0 AND safe_display IS NULL) OR (state=1 AND safe_display IS NOT NULL))"
            ");PRAGMA user_version=6;COMMIT;", NULL, NULL, NULL);
        if (code != SQLITE_OK) sqlite3_exec(store->database, "ROLLBACK;", NULL, NULL, NULL);
        if (code != SQLITE_OK) return vault_status(code);
        version = 6;
    }
    if (version == 6) {
        code = sqlite3_exec(store->database,
            "BEGIN IMMEDIATE;"
            "CREATE TABLE vault_approval_keys("
            "owner_id TEXT NOT NULL CHECK(length(owner_id)>0 AND length(owner_id)<=256),"
            "peer_id TEXT NOT NULL CHECK(length(peer_id)>0 AND length(peer_id)<=256),"
            "public_key BLOB NOT NULL CHECK(length(public_key)=65),"
            "PRIMARY KEY(owner_id,peer_id));"
            "PRAGMA user_version=7;COMMIT;", NULL, NULL, NULL);
        if (code != SQLITE_OK) sqlite3_exec(store->database, "ROLLBACK;", NULL, NULL, NULL);
        if (code != SQLITE_OK) return vault_status(code);
        version = 7;
    }
    if (version != 7) return MemorySQLCipherStatusDatabaseError;

    int pending = 0;
    code = scalar_pending(store->database, &pending);
    if (code != SQLITE_OK) return MemorySQLCipherStatusDatabaseError;
    sqlite3_stmt *inventory = NULL;
    code = sqlite3_prepare_v2(store->database,
        "SELECT item_id FROM vault_item_inventory LIMIT 0;", -1, &inventory, NULL);
    sqlite3_finalize(inventory);
    if (code == SQLITE_OK) {
        sqlite3_stmt *keys = NULL;
        code = sqlite3_prepare_v2(store->database,
            "SELECT public_key FROM vault_approval_keys LIMIT 0;", -1, &keys, NULL);
        sqlite3_finalize(keys);
    }
    return vault_status(code);
}

MemorySQLCipherStatus memory_sqlcipher_require_active(MemorySQLCipherStore *store) {
    if (store == NULL || store->database == NULL) return MemorySQLCipherStatusInvalidArgument;
    int pending = 0;
    int code = scalar_pending(store->database, &pending);
    if (code != SQLITE_OK) return MemorySQLCipherStatusDatabaseError;
    return pending ? MemorySQLCipherStatusErasurePending : MemorySQLCipherStatusOK;
}

MemorySQLCipherStatus memory_sqlcipher_register_vault_item(MemorySQLCipherStore *store,
                                                            const uint8_t *identifierBytes,
                                                            size_t identifierLength) {
    if (store == NULL || store->database == NULL || !valid_uuid(identifierBytes, identifierLength))
        return MemorySQLCipherStatusInvalidArgument;
    sqlite3 *db = store->database;
    int code = sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    if (code != SQLITE_OK) return vault_status(code);
    int pending = 0;
    code = scalar_pending(db, &pending);
    if (code == SQLITE_OK && pending) code = SQLITE_AUTH;
    sqlite3_stmt *statement = NULL;
    if (code == SQLITE_OK) code = sqlite3_prepare_v2(db,
        "SELECT count(*) FROM vault_item_inventory;", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    int count = code == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1;
    if (code == SQLITE_ROW) code = SQLITE_OK;
    sqlite3_finalize(statement);
    int exists = 0;
    if (code == SQLITE_OK) {
        code = sqlite3_prepare_v2(db,
            "SELECT 1 FROM vault_item_inventory WHERE item_id=?;", -1, &statement, NULL);
        if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1,
            (const char *)identifierBytes, (int)identifierLength, SQLITE_TRANSIENT);
        if (code == SQLITE_OK) code = sqlite3_step(statement);
        if (code == SQLITE_ROW) { exists = 1; code = SQLITE_OK; }
        else if (code == SQLITE_DONE) code = SQLITE_OK;
        sqlite3_finalize(statement);
    }
    if (code == SQLITE_OK && !exists && count >= VAULT_INVENTORY_LIMIT) code = SQLITE_TOOBIG;
    if (code == SQLITE_OK && !exists) {
        code = sqlite3_prepare_v2(db,
            "INSERT INTO vault_item_inventory(item_id) VALUES(?);", -1, &statement, NULL);
        if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1,
            (const char *)identifierBytes, (int)identifierLength, SQLITE_TRANSIENT);
        if (code == SQLITE_OK) code = sqlite3_step(statement);
        if (code == SQLITE_DONE) code = SQLITE_OK;
        sqlite3_finalize(statement);
    }
    if (code == SQLITE_OK) {
        code = sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
        if (code != SQLITE_OK) sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
    } else {
        sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
    }
    if (code == SQLITE_AUTH) return MemorySQLCipherStatusErasurePending;
    if (code == SQLITE_TOOBIG) return MemorySQLCipherStatusInvalidArgument;
    return vault_status(code);
}

MemorySQLCipherStatus memory_sqlcipher_begin_vault_erasure(MemorySQLCipherStore *store) {
    if (store == NULL || store->database == NULL) return MemorySQLCipherStatusInvalidArgument;
    int code = sqlite3_exec(store->database,
        "BEGIN IMMEDIATE;UPDATE memory_lifecycle SET vault_erasure_pending=1 WHERE singleton=1;",
        NULL, NULL, NULL);
    if (code == SQLITE_OK && sqlite3_changes(store->database) != 1) code = SQLITE_CORRUPT;
    if (code == SQLITE_OK) code = sqlite3_exec(store->database, "COMMIT;", NULL, NULL, NULL);
    if (code != SQLITE_OK) sqlite3_exec(store->database, "ROLLBACK;", NULL, NULL, NULL);
    return vault_status(code);
}

MemorySQLCipherStatus memory_sqlcipher_vault_inventory(MemorySQLCipherStore *store,
                                                        uint8_t **bytesOut, size_t *lengthOut) {
    if (store == NULL || store->database == NULL || bytesOut == NULL || lengthOut == NULL)
        return MemorySQLCipherStatusInvalidArgument;
    *bytesOut = NULL; *lengthOut = 0;
    int pending = 0;
    int code = scalar_pending(store->database, &pending);
    if (code != SQLITE_OK) return MemorySQLCipherStatusDatabaseError;
    if (!pending) return MemorySQLCipherStatusInvalidArgument;
    uint8_t *bytes = calloc(VAULT_INVENTORY_LIMIT, VAULT_UUID_BYTES);
    if (bytes == NULL) return MemorySQLCipherStatusOutOfMemory;
    sqlite3_stmt *statement = NULL;
    code = sqlite3_prepare_v2(store->database,
        "SELECT item_id FROM vault_item_inventory ORDER BY item_id COLLATE BINARY;", -1, &statement, NULL);
    size_t count = 0;
    if (code == SQLITE_OK) {
        while ((code = sqlite3_step(statement)) == SQLITE_ROW) {
            const uint8_t *item = sqlite3_column_text(statement, 0);
            int length = sqlite3_column_bytes(statement, 0);
            if (count == VAULT_INVENTORY_LIMIT || !valid_uuid(item, (size_t)length)) {
                code = SQLITE_CORRUPT; break;
            }
            memcpy(bytes + count * VAULT_UUID_BYTES, item, VAULT_UUID_BYTES);
            count++;
        }
    }
    sqlite3_finalize(statement);
    if (code != SQLITE_DONE) { free(bytes); return vault_status(code); }
    if (count == 0) { free(bytes); return MemorySQLCipherStatusOK; }
    *bytesOut = bytes; *lengthOut = count * VAULT_UUID_BYTES;
    return MemorySQLCipherStatusOK;
}

void memory_sqlcipher_free_bytes(void *bytes) { free(bytes); }

static int valid_command_key(const uint8_t *bytes, size_t length) {
    if (bytes == NULL || length != 64) return 0;
    for (size_t i = 0; i < length; i++)
        if (!((bytes[i] >= '0' && bytes[i] <= '9') || (bytes[i] >= 'a' && bytes[i] <= 'f'))) return 0;
    return 1;
}

static int valid_vault_kind(const uint8_t *bytes, size_t length) {
    static const char *const kinds[] = {"paymentCard", "address", "phone", "membership", "identity"};
    if (bytes == NULL) return 0;
    for (size_t i = 0; i < sizeof(kinds) / sizeof(kinds[0]); i++)
        if (strlen(kinds[i]) == length && memcmp(bytes, kinds[i], length) == 0) return 1;
    return 0;
}

static int valid_owner(const uint8_t *bytes, size_t length) {
    return bytes != NULL && length > 0 && length <= 256 && memchr(bytes, 0, length) == NULL;
}

static char *copy_column(sqlite3_stmt *statement, int column, int required, int maximumLength) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) return NULL;
    if (sqlite3_column_type(statement, column) != SQLITE_TEXT) return NULL;
    const unsigned char *value = sqlite3_column_text(statement, column);
    int length = sqlite3_column_bytes(statement, column);
    if (value == NULL || length < (required ? 1 : 0) || length > maximumLength
        || memchr(value, 0, (size_t)length) != NULL) return NULL;
    char *copy = calloc((size_t)length + 1, 1);
    if (copy == NULL) return NULL;
    memcpy(copy, value, (size_t)length);
    return copy;
}

MemorySQLCipherStatus memory_sqlcipher_reserve_vault_create(MemorySQLCipherStore *store,
                                                             const uint8_t *commandKey, size_t commandKeyLength,
                                                             const uint8_t *ownerID, size_t ownerIDLength,
                                                             const uint8_t *itemID, size_t itemIDLength,
                                                             const uint8_t *kind, size_t kindLength) {
    if (store == NULL || store->database == NULL || !valid_command_key(commandKey, commandKeyLength)
        || !valid_owner(ownerID, ownerIDLength) || !valid_uuid(itemID, itemIDLength)
        || !valid_vault_kind(kind, kindLength)) return MemorySQLCipherStatusInvalidArgument;
    sqlite3 *db = store->database;
    int code = sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    if (code != SQLITE_OK) return vault_status(code);
    int pending = 0;
    code = scalar_pending(db, &pending);
    if (code == SQLITE_OK && pending) code = SQLITE_AUTH;
    sqlite3_stmt *statement = NULL;
    if (code == SQLITE_OK) code = sqlite3_prepare_v2(db,
        "SELECT count(*) FROM vault_item_inventory;", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    int count = code == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1;
    if (code == SQLITE_ROW) code = SQLITE_OK;
    sqlite3_finalize(statement); statement = NULL;
    if (code == SQLITE_OK && count >= VAULT_INVENTORY_LIMIT) code = SQLITE_TOOBIG;
    if (code == SQLITE_OK) code = sqlite3_prepare_v2(db,
        "INSERT INTO vault_item_inventory(item_id) VALUES(?);", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1, (const char *)itemID,
                                                     (int)itemIDLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    if (code == SQLITE_DONE) code = SQLITE_OK;
    sqlite3_finalize(statement); statement = NULL;
    if (code == SQLITE_OK) code = sqlite3_prepare_v2(db,
        "INSERT INTO vault_create_reservations(command_key,owner_id,item_id,kind,state,safe_display)"
        " VALUES(?,?,?,?,0,NULL);", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1, (const char *)commandKey,
                                                     (int)commandKeyLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 2, (const char *)ownerID,
                                                     (int)ownerIDLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 3, (const char *)itemID,
                                                     (int)itemIDLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 4, (const char *)kind,
                                                     (int)kindLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    if (code == SQLITE_DONE) code = SQLITE_OK;
    sqlite3_finalize(statement);
    if (code == SQLITE_OK) code = sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    if (code != SQLITE_OK) sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
    if (code == SQLITE_AUTH) return MemorySQLCipherStatusErasurePending;
    if (code == SQLITE_TOOBIG) return MemorySQLCipherStatusInvalidArgument;
    return vault_status(code);
}

MemorySQLCipherStatus memory_sqlcipher_complete_vault_create(MemorySQLCipherStore *store,
                                                              const uint8_t *commandKey, size_t commandKeyLength,
                                                              const uint8_t *ownerID, size_t ownerIDLength,
                                                              const uint8_t *itemID, size_t itemIDLength,
                                                              const uint8_t *displayText, size_t displayLength) {
    if (store == NULL || store->database == NULL || !valid_command_key(commandKey, commandKeyLength)
        || !valid_owner(ownerID, ownerIDLength) || !valid_uuid(itemID, itemIDLength)
        || displayText == NULL || displayLength == 0 || displayLength > 256
        || memchr(displayText, 0, displayLength) != NULL) return MemorySQLCipherStatusInvalidArgument;
    sqlite3 *db = store->database;
    int code = sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    if (code != SQLITE_OK) return vault_status(code);
    int pending = 0;
    code = scalar_pending(db, &pending);
    if (code == SQLITE_OK && pending) code = SQLITE_AUTH;
    sqlite3_stmt *statement = NULL;
    if (code == SQLITE_OK) code = sqlite3_prepare_v2(db,
        "INSERT INTO vault_handle_displays(handle,safe_display) VALUES(?,?);", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1, (const char *)itemID,
                                                     (int)itemIDLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 2, (const char *)displayText,
                                                     (int)displayLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    if (code == SQLITE_DONE) code = SQLITE_OK;
    sqlite3_finalize(statement); statement = NULL;
    if (code == SQLITE_OK) code = sqlite3_prepare_v2(db,
        "UPDATE vault_create_reservations SET state=1,safe_display=?"
        " WHERE command_key=? AND owner_id=? AND item_id=? AND state=0;", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1, (const char *)displayText,
                                                     (int)displayLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 2, (const char *)commandKey,
                                                     (int)commandKeyLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 3, (const char *)ownerID,
                                                     (int)ownerIDLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 4, (const char *)itemID,
                                                     (int)itemIDLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    if (code == SQLITE_DONE && sqlite3_changes(db) != 1) code = SQLITE_NOTFOUND;
    else if (code == SQLITE_DONE) code = SQLITE_OK;
    sqlite3_finalize(statement);
    if (code == SQLITE_OK) code = sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    if (code != SQLITE_OK) sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
    if (code == SQLITE_AUTH) return MemorySQLCipherStatusErasurePending;
    if (code == SQLITE_NOTFOUND) return MemorySQLCipherStatusNotFound;
    return vault_status(code);
}

MemorySQLCipherStatus memory_sqlcipher_vault_create_status(MemorySQLCipherStore *store,
                                                            const uint8_t *commandKey, size_t commandKeyLength,
                                                            const uint8_t *ownerID, size_t ownerIDLength,
                                                            MemorySQLCipherVaultCreateStatus *statusOut) {
    if (store == NULL || store->database == NULL || !valid_command_key(commandKey, commandKeyLength)
        || !valid_owner(ownerID, ownerIDLength) || statusOut == NULL) return MemorySQLCipherStatusInvalidArgument;
    memset(statusOut, 0, sizeof(*statusOut));
    sqlite3_stmt *statement = NULL;
    int code = sqlite3_prepare_v2(store->database,
        "SELECT item_id,kind,state,safe_display FROM vault_create_reservations"
        " WHERE command_key=? AND owner_id=?;", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1, (const char *)commandKey,
                                                     (int)commandKeyLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 2, (const char *)ownerID,
                                                     (int)ownerIDLength, SQLITE_TRANSIENT);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    if (code == SQLITE_ROW) {
        statusOut->itemID = copy_column(statement, 0, 1, VAULT_UUID_BYTES);
        statusOut->kind = copy_column(statement, 1, 1, 32);
        if (sqlite3_column_type(statement, 2) != SQLITE_INTEGER) code = SQLITE_CORRUPT;
        else {
            sqlite3_int64 state = sqlite3_column_int64(statement, 2);
            if (state != 0 && state != 1) code = SQLITE_CORRUPT;
            else statusOut->state = (int)state;
        }
        if (statusOut->state == 1) statusOut->displayText = copy_column(statement, 3, 1, 256);
        else if (sqlite3_column_type(statement, 3) != SQLITE_NULL) code = SQLITE_CORRUPT;
        if (statusOut->itemID == NULL || statusOut->kind == NULL
            || (statusOut->state != 0 && statusOut->state != 1)
            || (statusOut->state == 1 && statusOut->displayText == NULL)) code = SQLITE_CORRUPT;
        else if (code == SQLITE_ROW) code = SQLITE_OK;
    } else if (code == SQLITE_DONE) code = SQLITE_NOTFOUND;
    sqlite3_finalize(statement);
    if (code == SQLITE_NOTFOUND) return MemorySQLCipherStatusNotFound;
    if (code != SQLITE_OK) { memory_sqlcipher_free_vault_create_status(statusOut); return vault_status(code); }
    return MemorySQLCipherStatusOK;
}

void memory_sqlcipher_free_vault_create_status(MemorySQLCipherVaultCreateStatus *status) {
    if (status == NULL) return;
    free(status->itemID); free(status->kind); free(status->displayText);
    memset(status, 0, sizeof(*status));
}

MemorySQLCipherStatus memory_sqlcipher_complete_vault_erasure(MemorySQLCipherStore *store) {
    if (store == NULL || store->database == NULL) return MemorySQLCipherStatusInvalidArgument;
    int code = sqlite3_exec(store->database, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    int pending = 0;
    if (code == SQLITE_OK) code = scalar_pending(store->database, &pending);
    if (code == SQLITE_OK && !pending) code = SQLITE_MISUSE;
    if (code == SQLITE_OK) code = sqlite3_exec(store->database,
        "DELETE FROM vault_item_inventory;DELETE FROM vault_create_reservations;"
        "DELETE FROM vault_approval_keys;COMMIT;", NULL, NULL, NULL);
    if (code != SQLITE_OK) sqlite3_exec(store->database, "ROLLBACK;", NULL, NULL, NULL);
    return vault_status(code);
}

MemorySQLCipherStatus memory_sqlcipher_vault_erasure_pending(MemorySQLCipherStore *store,
                                                             int *pendingOut) {
    if (store == NULL || store->database == NULL || pendingOut == NULL)
        return MemorySQLCipherStatusInvalidArgument;
    return vault_status(scalar_pending(store->database, pendingOut));
}

MemorySQLCipherStatus memory_sqlcipher_delete_all(MemorySQLCipherStore *store) {
    if (store == NULL || store->database == NULL) return MemorySQLCipherStatusInvalidArgument;
    sqlite3 *db = store->database;
    int code = sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    if (code != SQLITE_OK) return vault_status(code);
    sqlite3_stmt *statement = NULL;
    code = sqlite3_prepare_v2(db, "SELECT count(*) FROM vault_item_inventory;", -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    int count = code == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1;
    sqlite3_finalize(statement);
    if (code == SQLITE_ROW && count > 0) code = SQLITE_AUTH;
    if (code == SQLITE_ROW) code = SQLITE_OK;
    if (code == SQLITE_OK) code = sqlite3_exec(db,
        "DELETE FROM memory_items;DELETE FROM vault_handle_displays;DELETE FROM owner_command_receipts;"
        "DELETE FROM vault_create_reservations;DELETE FROM vault_approval_keys;",
        NULL, NULL, NULL);
    if (code == SQLITE_OK) code = sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    if (code != SQLITE_OK) sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
    if (code == SQLITE_AUTH) return MemorySQLCipherStatusErasurePending;
    return vault_status(code);
}
