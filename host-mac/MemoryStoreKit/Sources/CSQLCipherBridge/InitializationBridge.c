#include "MemorySQLCipherInternal.h"

/// Returns only whether the fixed app-owned content tables contain rows. It never returns or
/// formats memory values, identifiers, receipts, or vault labels.
MemorySQLCipherStatus memory_sqlcipher_require_empty_for_initialization(MemorySQLCipherStore *store) {
    if (store == NULL || store->database == NULL) return MemorySQLCipherStatusInvalidArgument;

    MemorySQLCipherStatus active = memory_sqlcipher_require_active(store);
    if (active != MemorySQLCipherStatusOK) return active;

    static const char *sql =
        "SELECT "
        "EXISTS(SELECT 1 FROM memory_items LIMIT 1) OR "
        "EXISTS(SELECT 1 FROM vault_handle_displays LIMIT 1) OR "
        "EXISTS(SELECT 1 FROM owner_command_receipts LIMIT 1) OR "
        "EXISTS(SELECT 1 FROM vault_item_inventory LIMIT 1) OR "
        "EXISTS(SELECT 1 FROM vault_create_reservations LIMIT 1) OR "
        "EXISTS(SELECT 1 FROM vault_approval_keys LIMIT 1) OR "
        "EXISTS(SELECT 1 FROM memory_fts_data WHERE id NOT IN (1,10) LIMIT 1) OR "
        "EXISTS(SELECT 1 FROM memory_fts_idx LIMIT 1) OR "
        "EXISTS(SELECT 1 FROM memory_fts_docsize LIMIT 1);";
    sqlite3_stmt *statement = NULL;
    int code = sqlite3_prepare_v2(store->database, sql, -1, &statement, NULL);
    if (code == SQLITE_OK) code = sqlite3_step(statement);
    MemorySQLCipherStatus result = MemorySQLCipherStatusDatabaseError;
    if (code == SQLITE_ROW && sqlite3_column_type(statement, 0) == SQLITE_INTEGER) {
        int contentPresent = sqlite3_column_int(statement, 0);
        if (contentPresent == 0) result = MemorySQLCipherStatusOK;
        else if (contentPresent == 1) result = MemorySQLCipherStatusContentPresent;
    } else if (code == SQLITE_NOMEM) {
        result = MemorySQLCipherStatusOutOfMemory;
    }
    sqlite3_finalize(statement);
    return result;
}
