#ifndef CSQLCIPHERBRIDGE_H
#define CSQLCIPHERBRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef struct MemorySQLCipherStore MemorySQLCipherStore;

typedef enum MemorySQLCipherStatus {
    MemorySQLCipherStatusOK = 0,
    MemorySQLCipherStatusInvalidArgument = 1,
    MemorySQLCipherStatusCryptoUnavailable = 2,
    MemorySQLCipherStatusAuthenticationFailed = 3,
    MemorySQLCipherStatusDatabaseError = 4,
    MemorySQLCipherStatusOutOfMemory = 5,
    MemorySQLCipherStatusConflict = 6,
    MemorySQLCipherStatusNotFound = 7,
    MemorySQLCipherStatusErasurePending = 8,
    MemorySQLCipherStatusContentPresent = 9
} MemorySQLCipherStatus;

typedef struct MemorySQLCipherSearchRow {
    char *identifier;
    char *recordType;
    char *body;
    char *source;
    char *sourceMessageID;
    char *proposalID;
    char *statementID;
    char *candidateOrigin;
    char *sourceReference;
    char *sourceSpan;
    int64_t observedAt;
    int status;
    double confidence;
    double bm25Rank;
} MemorySQLCipherSearchRow;

/* Ordinary export rows omit all lineage and provenance columns. */
typedef struct MemorySQLCipherExportRow {
    char *identifier;
    char *recordType;
    char *body;
    char *source;
    int64_t observedAt;
    int status;
    double confidence;
} MemorySQLCipherExportRow;

typedef struct MemorySQLCipherProposalReceipt {
    char *ownerID;
    char *sessionID;
    char *taskID;
    char *commandKey;
    char *recordID;
    int64_t expiresAt;
} MemorySQLCipherProposalReceipt;

typedef struct MemorySQLCipherVaultCreateStatus {
    char *itemID;
    char *kind;
    char *displayText;
    int state;
} MemorySQLCipherVaultCreateStatus;

MemorySQLCipherStatus memory_sqlcipher_open(const char *path,
                                            const uint8_t *keyBytes,
                                            size_t keyLength,
                                            MemorySQLCipherStore **storeOut);
MemorySQLCipherStatus memory_sqlcipher_create_schema(MemorySQLCipherStore *store);
MemorySQLCipherStatus memory_sqlcipher_upsert_record(MemorySQLCipherStore *store,
                                                     const uint8_t *identifierBytes,
                                                     size_t identifierLength,
                                                     const uint8_t *recordTypeBytes,
                                                     size_t recordTypeLength,
                                                     const uint8_t *bodyBytes,
                                                     size_t bodyLength,
                                                     const uint8_t *sourceBytes,
                                                     size_t sourceLength,
                                                     const uint8_t *sourceMessageIDBytes,
                                                     size_t sourceMessageIDLength,
                                                     const uint8_t *proposalIDBytes,
                                                     size_t proposalIDLength,
                                                     const uint8_t *statementIDBytes,
                                                     size_t statementIDLength,
                                                     const uint8_t *candidateOriginBytes,
                                                     size_t candidateOriginLength,
                                                     const uint8_t *sourceReferenceBytes,
                                                     size_t sourceReferenceLength,
                                                     const uint8_t *sourceSpanBytes,
                                                     size_t sourceSpanLength,
                                                     int64_t observedAt,
                                                     int status,
                                                     double confidence);
MemorySQLCipherStatus memory_sqlcipher_commit_owner_command(MemorySQLCipherStore *store,
                                                            const uint8_t *commandBytes,
                                                            size_t commandLength,
                                                            const uint8_t *digestBytes,
                                                            size_t digestLength,
                                                            const uint8_t *identifierBytes,
                                                            size_t identifierLength,
                                                            const uint8_t *recordTypeBytes,
                                                            size_t recordTypeLength,
                                                            const uint8_t *bodyBytes,
                                                            size_t bodyLength,
                                                            const uint8_t *sourceBytes,
                                                            size_t sourceLength,
                                                            const uint8_t *sourceMessageIDBytes,
                                                            size_t sourceMessageIDLength,
                                                            const uint8_t *proposalIDBytes,
                                                            size_t proposalIDLength,
                                                            const uint8_t *statementIDBytes,
                                                            size_t statementIDLength,
                                                            const uint8_t *ownerIDBytes,
                                                            size_t ownerIDLength,
                                                            const uint8_t *sessionIDBytes,
                                                            size_t sessionIDLength,
                                                            const uint8_t *taskIDBytes,
                                                            size_t taskIDLength,
                                                            int64_t proposalExpiresAt,
                                                            const uint8_t *candidateOriginBytes,
                                                            size_t candidateOriginLength,
                                                            const uint8_t *sourceReferenceBytes,
                                                            size_t sourceReferenceLength,
                                                            const uint8_t *sourceSpanBytes,
                                                            size_t sourceSpanLength,
                                                            int64_t observedAt,
                                                            double confidence,
                                                            char **recordIDOut,
                                                            int *idempotentOut);
/* Record snapshot encoding: four length-prefixed UTF-8 fields, then int64 BE, status byte,
   confidence IEEE-754 bits BE, then six length-prefixed optional UTF-8 provenance fields. */
MemorySQLCipherStatus memory_sqlcipher_edit_owner_record(MemorySQLCipherStore *store,
                                                         const uint8_t *commandBytes, size_t commandLength,
                                                         const uint8_t *digestBytes, size_t digestLength,
                                                         const uint8_t *expectedBytes, size_t expectedLength,
                                                         int revisionMatches,
                                                         const uint8_t *replacementBytes, size_t replacementLength,
                                                         char **recordIDOut, int *idempotentOut);
MemorySQLCipherStatus memory_sqlcipher_get_proposal_receipt(MemorySQLCipherStore *store,
                                                            const uint8_t *proposalIDBytes,
                                                            size_t proposalIDLength,
                                                            MemorySQLCipherProposalReceipt *receiptOut);
void memory_sqlcipher_free_proposal_receipt(MemorySQLCipherProposalReceipt *receipt);
void memory_sqlcipher_free_text(char *text);
MemorySQLCipherStatus memory_sqlcipher_upsert_vault_display(MemorySQLCipherStore *store,
                                                            const uint8_t *handleBytes,
                                                            size_t handleLength,
                                                            const uint8_t *safeDisplayBytes,
                                                            size_t safeDisplayLength);
MemorySQLCipherStatus memory_sqlcipher_search(MemorySQLCipherStore *store,
                                              const uint8_t *queryBytes,
                                              size_t queryLength,
                                              int limit,
                                              MemorySQLCipherSearchRow **rowsOut,
                                              size_t *countOut);
MemorySQLCipherStatus memory_sqlcipher_get(MemorySQLCipherStore *store,
                                           const uint8_t *identifierBytes,
                                           size_t identifierLength,
                                           MemorySQLCipherSearchRow **rowOut);
MemorySQLCipherStatus memory_sqlcipher_list(MemorySQLCipherStore *store,
                                            int includeInactive,
                                            int limit,
                                            MemorySQLCipherSearchRow **rowsOut,
                                            size_t *countOut);
MemorySQLCipherStatus memory_sqlcipher_owner_page(MemorySQLCipherStore *store,
                                                  const uint8_t *queryBytes,
                                                  size_t queryLength,
                                                  const uint8_t *afterBytes,
                                                  size_t afterLength,
                                                  int limit,
                                                  MemorySQLCipherSearchRow **rowsOut,
                                                  size_t *countOut);
MemorySQLCipherStatus memory_sqlcipher_export_rows(MemorySQLCipherStore *store,
                                                    int limit, size_t maximumBodyBytes,
                                                    size_t maximumTotalBytes,
                                                    MemorySQLCipherExportRow **rowsOut,
                                                    size_t *countOut);
void memory_sqlcipher_free_export_rows(MemorySQLCipherExportRow *rows, size_t count);
void memory_sqlcipher_free_search_rows(MemorySQLCipherSearchRow *rows, size_t count);
MemorySQLCipherStatus memory_sqlcipher_delete(MemorySQLCipherStore *store,
                                              const uint8_t *identifierBytes,
                                              size_t identifierLength);
MemorySQLCipherStatus memory_sqlcipher_update_status(MemorySQLCipherStore *store,
                                                     const uint8_t *identifierBytes,
                                                     size_t identifierLength,
                                                     int active);
MemorySQLCipherStatus memory_sqlcipher_delete_all(MemorySQLCipherStore *store);
MemorySQLCipherStatus memory_sqlcipher_enroll_vault_approval_key(MemorySQLCipherStore *store,
                                                                  const uint8_t *owner, size_t ownerLength,
                                                                  const uint8_t *peer, size_t peerLength,
                                                                  const uint8_t *key, size_t keyLength);
MemorySQLCipherStatus memory_sqlcipher_get_vault_approval_key(MemorySQLCipherStore *store,
                                                               const uint8_t *owner, size_t ownerLength,
                                                               const uint8_t *peer, size_t peerLength,
                                                               uint8_t **keyOut, size_t *keyLengthOut);
MemorySQLCipherStatus memory_sqlcipher_create_vault_inventory_schema(MemorySQLCipherStore *store);
MemorySQLCipherStatus memory_sqlcipher_require_active(MemorySQLCipherStore *store);
MemorySQLCipherStatus memory_sqlcipher_require_empty_for_initialization(MemorySQLCipherStore *store);
MemorySQLCipherStatus memory_sqlcipher_register_vault_item(MemorySQLCipherStore *store,
                                                            const uint8_t *identifierBytes,
                                                            size_t identifierLength);
MemorySQLCipherStatus memory_sqlcipher_begin_vault_erasure(MemorySQLCipherStore *store);
MemorySQLCipherStatus memory_sqlcipher_vault_inventory(MemorySQLCipherStore *store,
                                                        uint8_t **bytesOut, size_t *lengthOut);
void memory_sqlcipher_free_bytes(void *bytes);
MemorySQLCipherStatus memory_sqlcipher_complete_vault_erasure(MemorySQLCipherStore *store);
MemorySQLCipherStatus memory_sqlcipher_reserve_vault_create(MemorySQLCipherStore *store,
                                                             const uint8_t *commandKey, size_t commandKeyLength,
                                                             const uint8_t *ownerID, size_t ownerIDLength,
                                                             const uint8_t *itemID, size_t itemIDLength,
                                                             const uint8_t *kind, size_t kindLength);
MemorySQLCipherStatus memory_sqlcipher_complete_vault_create(MemorySQLCipherStore *store,
                                                              const uint8_t *commandKey, size_t commandKeyLength,
                                                              const uint8_t *ownerID, size_t ownerIDLength,
                                                              const uint8_t *itemID, size_t itemIDLength,
                                                              const uint8_t *displayText, size_t displayLength);
MemorySQLCipherStatus memory_sqlcipher_vault_create_status(MemorySQLCipherStore *store,
                                                            const uint8_t *commandKey, size_t commandKeyLength,
                                                            const uint8_t *ownerID, size_t ownerIDLength,
                                                            MemorySQLCipherVaultCreateStatus *statusOut);
void memory_sqlcipher_free_vault_create_status(MemorySQLCipherVaultCreateStatus *status);
MemorySQLCipherStatus memory_sqlcipher_vault_erasure_pending(MemorySQLCipherStore *store,
                                                             int *pendingOut);
MemorySQLCipherStatus memory_sqlcipher_checkpoint(MemorySQLCipherStore *store);
MemorySQLCipherStatus memory_sqlcipher_close(MemorySQLCipherStore **store);


#endif
