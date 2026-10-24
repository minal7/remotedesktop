#ifndef MEMORY_SQLCIPHER_INTERNAL_H
#define MEMORY_SQLCIPHER_INTERNAL_H

#include "CSQLCipherBridge.h"
#include "../../../ThirdPartyRuntime/sqlcipher/build/778ab890cfc30c3631212dcceb0295498abdcd3e/include/sqlite3.h"

struct MemorySQLCipherStore {
    sqlite3 *database;
};

#endif
