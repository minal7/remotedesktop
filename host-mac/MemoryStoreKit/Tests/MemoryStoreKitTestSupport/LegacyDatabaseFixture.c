#include "MemoryStoreKitTestSupport.h"
#include <sqlite3.h>
#include <stdio.h>

static int execute(sqlite3 *database, const char *sql) {
    char *message = NULL;
    int code = sqlite3_exec(database, sql, NULL, NULL, &message);
    sqlite3_free(message);
    return code;
}

static int open_database(const char *path, const uint8_t *key, size_t key_length,
                         int flags, sqlite3 **database_out) {
    if (path == NULL || key == NULL || key_length != 32 || database_out == NULL) return SQLITE_MISUSE;
    *database_out = NULL;
    int code = sqlite3_open_v2(path, database_out, flags, NULL);
    if (code == SQLITE_OK) code = sqlite3_key(*database_out, key, (int)key_length);
    if (code != SQLITE_OK && *database_out != NULL) {
        sqlite3_close_v2(*database_out);
        *database_out = NULL;
    }
    return code;
}

int memory_test_create_legacy_database(const char *path, const uint8_t *key, size_t key_length,
                                       int schema_version, int migration_conflict) {
    if (schema_version < 0 || schema_version > 99 ||
        (migration_conflict != 0 && migration_conflict != 1)) return SQLITE_MISUSE;
    sqlite3 *database = NULL;
    int code = open_database(path, key, key_length,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, &database);
    if (code != SQLITE_OK) return code;
    code = execute(database,
        "CREATE TABLE memory_items(id TEXT PRIMARY KEY NOT NULL,kind TEXT NOT NULL,body TEXT NOT NULL,"
        "source TEXT NOT NULL,observed_at INTEGER NOT NULL,status INTEGER NOT NULL,confidence REAL NOT NULL);"
        "CREATE VIRTUAL TABLE memory_fts USING fts5(body,content='memory_items',content_rowid='rowid');"
        "CREATE TRIGGER memory_items_ai AFTER INSERT ON memory_items BEGIN "
        "INSERT INTO memory_fts(rowid,body) VALUES(new.rowid,new.body); END;"
        "CREATE TRIGGER memory_items_ad AFTER DELETE ON memory_items BEGIN "
        "INSERT INTO memory_fts(memory_fts,rowid,body) VALUES('delete',old.rowid,old.body); END;"
        "CREATE TRIGGER memory_items_au AFTER UPDATE ON memory_items BEGIN "
        "INSERT INTO memory_fts(memory_fts,rowid,body) VALUES('delete',old.rowid,old.body);"
        "INSERT INTO memory_fts(rowid,body) VALUES(new.rowid,new.body); END;"
        "CREATE TABLE vault_handle_displays(handle TEXT PRIMARY KEY NOT NULL,safe_display TEXT NOT NULL);"
        "INSERT INTO memory_items VALUES('legacy-row','fact','migration canary','owner_message',7,1,0.75);"
        "INSERT INTO vault_handle_displays VALUES('legacy-handle','untrusted legacy display');");
    if (code == SQLITE_OK && migration_conflict) {
        code = execute(database, "ALTER TABLE memory_items ADD COLUMN proposal_id TEXT;");
    }
    if (code == SQLITE_OK && schema_version >= 2 && !migration_conflict) {
        code = execute(database,
            "ALTER TABLE memory_items ADD COLUMN source_message_id TEXT;"
            "ALTER TABLE memory_items ADD COLUMN proposal_id TEXT;"
            "ALTER TABLE memory_items ADD COLUMN statement_id TEXT;");
    }
    if (code == SQLITE_OK && schema_version >= 3 && !migration_conflict) {
        code = execute(database,
            "CREATE TABLE owner_command_receipts(command_id TEXT PRIMARY KEY NOT NULL,"
            "payload_digest BLOB NOT NULL CHECK(length(payload_digest)=32),record_id TEXT NOT NULL);");
    }
    if (code == SQLITE_OK && schema_version >= 4 && !migration_conflict) {
        code = execute(database,
            "ALTER TABLE memory_items ADD COLUMN candidate_origin TEXT;"
            "ALTER TABLE memory_items ADD COLUMN source_reference TEXT;"
            "ALTER TABLE memory_items ADD COLUMN source_span TEXT;"
            "ALTER TABLE owner_command_receipts ADD COLUMN proposal_id TEXT;"
            "ALTER TABLE owner_command_receipts ADD COLUMN owner_id TEXT;"
            "ALTER TABLE owner_command_receipts ADD COLUMN session_id TEXT;"
            "ALTER TABLE owner_command_receipts ADD COLUMN task_id TEXT;"
            "ALTER TABLE owner_command_receipts ADD COLUMN expires_at INTEGER;"
            "CREATE UNIQUE INDEX owner_proposal_receipts_idx ON owner_command_receipts(proposal_id) "
            "WHERE proposal_id IS NOT NULL;");
    }
    if (code == SQLITE_OK && schema_version >= 5 && schema_version <= 6 && !migration_conflict) {
        code = execute(database,
            "CREATE TABLE vault_item_inventory(item_id TEXT PRIMARY KEY NOT NULL CHECK(length(item_id)=36));"
            "CREATE TABLE memory_lifecycle(singleton INTEGER PRIMARY KEY CHECK(singleton=1),"
            "vault_erasure_pending INTEGER NOT NULL CHECK(vault_erasure_pending IN (0,1)));"
            "INSERT INTO memory_lifecycle(singleton,vault_erasure_pending) VALUES(1,0);");
    }
    if (code == SQLITE_OK && schema_version == 6 && !migration_conflict) {
        code = execute(database,
            "CREATE TABLE vault_create_reservations("
            "command_key TEXT PRIMARY KEY NOT NULL CHECK(length(command_key)=64),"
            "owner_id TEXT NOT NULL CHECK(length(owner_id)>0),"
            "item_id TEXT NOT NULL UNIQUE CHECK(length(item_id)=36),"
            "kind TEXT NOT NULL CHECK(kind IN ('paymentCard','address','phone','membership','identity')) ,"
            "state INTEGER NOT NULL CHECK(state IN (0,1)),safe_display TEXT,"
            "CHECK((state=0 AND safe_display IS NULL) OR (state=1 AND safe_display IS NOT NULL)));"
            "INSERT INTO vault_create_reservations VALUES("
            "'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',"
            "'fixture-owner','00000000-0000-0000-0000-000000000001','phone',0,NULL);");
    }
    if (code == SQLITE_OK) {
        char version_sql[64];
        (void)snprintf(version_sql, sizeof(version_sql), "PRAGMA user_version=%d;", schema_version);
        code = execute(database, version_sql);
    }
    int close_code = sqlite3_close_v2(database);
    return code == SQLITE_OK ? close_code : code;
}

static int scalar_int(sqlite3 *database, const char *sql, int *value_out) {
    sqlite3_stmt *statement = NULL;
    int code = sqlite3_prepare_v2(database, sql, -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    if (code == SQLITE_ROW) {
        *value_out = sqlite3_column_int(statement, 0);
        code = SQLITE_OK;
    }
    sqlite3_finalize(statement);
    return code;
}

int memory_test_inspect_database(const char *path, const uint8_t *key, size_t key_length,
                                 int *version_out, int *lineage_mask_out,
                                 int *legacy_display_count_out, int *record_count_out) {
    if (version_out == NULL || lineage_mask_out == NULL || legacy_display_count_out == NULL ||
        record_count_out == NULL) return SQLITE_MISUSE;
    sqlite3 *database = NULL;
    int code = open_database(path, key, key_length, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, &database);
    if (code != SQLITE_OK) return code;
    code = scalar_int(database, "PRAGMA user_version;", version_out);
    static const char *columns[] = { "source_message_id", "proposal_id", "statement_id" };
    *lineage_mask_out = 0;
    for (int index = 0; code == SQLITE_OK && index < 3; index++) {
        sqlite3_stmt *statement = NULL;
        code = sqlite3_prepare_v2(database,
            "SELECT 1 FROM pragma_table_info('memory_items') WHERE name=?;", -1, &statement, NULL);
        if (code == SQLITE_OK) code = sqlite3_bind_text(statement, 1, columns[index], -1, SQLITE_STATIC);
        if (code == SQLITE_OK) code = sqlite3_step(statement);
        if (code == SQLITE_ROW) { *lineage_mask_out |= (1 << index); code = SQLITE_OK; }
        else if (code == SQLITE_DONE) code = SQLITE_OK;
        sqlite3_finalize(statement);
    }
    if (code == SQLITE_OK) code = scalar_int(database, "SELECT count(*) FROM vault_handle_displays;", legacy_display_count_out);
    if (code == SQLITE_OK) code = scalar_int(database, "SELECT count(*) FROM memory_items;", record_count_out);
    int close_code = sqlite3_close_v2(database);
    return code == SQLITE_OK ? close_code : code;
}

int memory_test_corrupt_vault_inventory(const char *path, const uint8_t *key, size_t key_length,
                                        int corruption) {
    if (corruption != 1 && corruption != 2) return SQLITE_MISUSE;
    sqlite3 *database = NULL;
    int code = open_database(path, key, key_length,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, &database);
    if (code != SQLITE_OK) return code;
    code = execute(database, corruption == 1
        ? "DELETE FROM memory_lifecycle WHERE singleton=1;"
        : "UPDATE vault_item_inventory SET item_id='zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz';"
          "UPDATE memory_lifecycle SET vault_erasure_pending=1 WHERE singleton=1;");
    int close_code = sqlite3_close_v2(database);
    return code == SQLITE_OK ? close_code : code;
}
