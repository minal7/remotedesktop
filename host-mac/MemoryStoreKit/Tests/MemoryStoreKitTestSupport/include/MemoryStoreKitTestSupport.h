#ifndef MEMORY_STORE_KIT_TEST_SUPPORT_H
#define MEMORY_STORE_KIT_TEST_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

int memory_test_create_legacy_database(const char *path, const uint8_t *key, size_t key_length,
                                       int schema_version, int migration_conflict);
int memory_test_inspect_database(const char *path, const uint8_t *key, size_t key_length,
                                 int *version_out, int *lineage_mask_out,
                                 int *legacy_display_count_out, int *record_count_out);
int memory_test_corrupt_vault_inventory(const char *path, const uint8_t *key, size_t key_length,
                                        int corruption);

#endif
