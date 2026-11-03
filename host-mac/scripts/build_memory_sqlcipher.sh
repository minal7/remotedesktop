#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVISION="778ab890cfc30c3631212dcceb0295498abdcd3e"
ARCHIVE="$REPO_ROOT/build/donor-audit/sqlcipher-$REVISION.tar.gz"
EXPECTED_SHA256="c7b3d762d0a06484133f9463ed17d1540fcbda65e417d5b4ed3d3532b4499c5a"
EXPECTED_BYTES="19028329"
OUTPUT_ROOT="$REPO_ROOT/host-mac/ThirdPartyRuntime/sqlcipher/build/$REVISION"
MANIFEST="$REPO_ROOT/host-mac/ThirdPartyRuntime/sqlcipher/source-manifest.json"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Pinned SQLCipher source archive is not staged: $ARCHIVE" >&2
  echo "Stage the source archive separately; this script has no download path." >&2
  exit 66
fi

actual_sha256="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
actual_bytes="$(/usr/bin/stat -f '%z' "$ARCHIVE")"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" || "$actual_bytes" != "$EXPECTED_BYTES" ]]; then
  echo "Pinned SQLCipher source archive digest or size mismatch." >&2
  exit 65
fi

if [[ -e "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
  if python3 "$SCRIPT_DIR/verify_memory_sqlcipher.py" --output "$OUTPUT_ROOT" --manifest "$MANIFEST"; then
    exit 0
  fi
  python3 "$SCRIPT_DIR/verify_memory_sqlcipher.py" --output "$OUTPUT_ROOT" \
    --manifest "$MANIFEST" --remove-owned-legacy-output
fi

# Autotools rejects source/build paths containing spaces. Keep its entire work
# tree under a unique short path, then publish only the static archive, header,
# and build record into the ignored project output directory.
TEMP_ROOT="$(/usr/bin/mktemp -d /tmp/sqlcipher-memory.XXXXXX)"
trap '/bin/rm -rf "$TEMP_ROOT"' EXIT
mkdir -p "$TEMP_ROOT/source" "$TEMP_ROOT/work"
tar -xzf "$ARCHIVE" -C "$TEMP_ROOT/source"
SOURCE_ROOT="$TEMP_ROOT/source/sqlcipher-$REVISION"
if [[ ! -x "$SOURCE_ROOT/configure" || ! -f "$SOURCE_ROOT/src/sqlcipher.c" || ! -f "$SOURCE_ROOT/src/crypto_cc.c" ]]; then
  echo "Pinned source archive layout is not the expected SQLCipher source tree." >&2
  exit 65
fi

cd "$TEMP_ROOT/work"
export CC="/usr/bin/clang"
BASE_CFLAGS="-O2 -fPIC -mmacosx-version-min=14.0 -DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown -DSQLITE_THREADSAFE=1 -DSQLCIPHER_CRYPTO_CC -DSQLITE_OMIT_LOAD_EXTENSION=1"
ARCHITECTURES=(arm64 x86_64)
for ARCH in "${ARCHITECTURES[@]}"; do
  ARCH_WORK="$TEMP_ROOT/work/$ARCH"
  mkdir -p "$ARCH_WORK"
  (
    cd "$ARCH_WORK"
    export CFLAGS="-arch $ARCH $BASE_CFLAGS"
    export LDFLAGS="-arch $ARCH -framework Security -framework CoreFoundation"

    "$SOURCE_ROOT/configure" \
      --enable-static \
      --disable-shared \
      --enable-fts5 \
      --disable-load-extension \
      --with-tempstore=always

    /usr/bin/make -j2 sqlite3.c sqlite3.h lib
    test -s libsqlite3.a
    test -s sqlite3.h
    mkdir -p "$TEMP_ROOT/architectures/$ARCH"
    /bin/cp libsqlite3.a "$TEMP_ROOT/architectures/$ARCH/libsqlcipher.a"
    /bin/cp sqlite3.h "$TEMP_ROOT/architectures/$ARCH/sqlite3.h"
  )
done

if ! /usr/bin/cmp -s "$TEMP_ROOT/architectures/arm64/sqlite3.h" \
    "$TEMP_ROOT/architectures/x86_64/sqlite3.h"; then
  echo "Pinned SQLCipher headers differ across architecture builds." >&2
  exit 65
fi
mkdir -p "$OUTPUT_ROOT/lib" "$OUTPUT_ROOT/include"
/usr/bin/lipo -create \
  "$TEMP_ROOT/architectures/arm64/libsqlcipher.a" \
  "$TEMP_ROOT/architectures/x86_64/libsqlcipher.a" \
  -output "$OUTPUT_ROOT/lib/libsqlcipher.a"
/bin/cp "$TEMP_ROOT/architectures/arm64/sqlite3.h" "$OUTPUT_ROOT/include/sqlite3.h"

cat > "$OUTPUT_ROOT/build-options.txt" <<'EOF'
source_commit=778ab890cfc30c3631212dcceb0295498abdcd3e
macos_deployment_target=14.0
sqlite_has_codec=1
sqlite_extra_init=sqlcipher_extra_init
sqlite_extra_shutdown=sqlcipher_extra_shutdown
sqlite_threadsafe=1
sqlite_temp_store=3 (configure --with-tempstore=always)
fts5=enabled (configure --enable-fts5)
loadable_extensions=disabled (configure --disable-load-extension and SQLITE_OMIT_LOAD_EXTENSION)
crypto_provider=CommonCrypto (SQLCIPHER_CRYPTO_CC)
library_architectures=arm64 x86_64 (lipo-combined static archive)
key_api=sqlite3_key typed byte API; no PRAGMA/command-line/environment key
build_network_fetches=none (staged archive required and checked before extraction)
EOF

OUTPUT_ROOT="$OUTPUT_ROOT" MANIFEST="$MANIFEST" python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["OUTPUT_ROOT"])
manifest = json.loads(Path(os.environ["MANIFEST"]).read_text(encoding="utf-8"))
artifacts = {}
for relative in ("lib/libsqlcipher.a", "include/sqlite3.h", "build-options.txt"):
    path = root / relative
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    artifacts[relative] = {"sha256": digest, "bytes": path.stat().st_size}
record = {
    "schemaVersion": 2,
    "source": {
        "sourceCommit": manifest["sourceCommit"],
        "archiveSHA256": manifest["archiveSHA256Observed"],
        "archiveBytes": manifest["archiveBytesObserved"],
        "libraryArchitectures": manifest["libraryArchitectures"],
    },
    "libraryArchitectures": manifest["libraryArchitectures"],
    "artifacts": artifacts,
}
(root / "build-record.json").write_text(
    json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

python3 "$SCRIPT_DIR/verify_memory_sqlcipher.py" --output "$OUTPUT_ROOT" --manifest "$MANIFEST"

echo "Built pinned SQLCipher into ignored output: $OUTPUT_ROOT"
echo "This script does not compile or run MemoryStoreKit tests."
