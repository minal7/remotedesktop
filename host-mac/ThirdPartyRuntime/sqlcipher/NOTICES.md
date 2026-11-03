# SQLCipher source notices

The offline source archive is staged outside version control at:

`build/donor-audit/sqlcipher-778ab890cfc30c3631212dcceb0295498abdcd3e.tar.gz`

Its SHA-256, upstream repository, release tag object, and resolved commit are recorded in `source-manifest.json`. The archive was fetched from GitHub's codeload URL pinned to the commit. The SHA-256 is the locally observed archive digest; upstream does not publish an independent digest for this source archive. The resolved Git commit pins the source tree. The build script refuses to extract the archive if its bytes do not match the recorded digest.

SQLCipher changes and SQLCipher-specific code are under the BSD 3-Clause terms in the pinned upstream `LICENSE.md`. SQLite's core source is public domain as described in pinned `SQLITE_LICENSE.md`. Preserve both notices in any redistributed build. The selected SQLCipher crypto adapter uses CommonCrypto, Security.framework random bytes, and CoreFoundation from the Apple SDK; do not add OpenSSL or LibTomCrypt.

The staged source and generated build products are intentionally ignored under `build/` and `ThirdPartyRuntime/sqlcipher/build/`; no generated dependency source or compiled library is committed.
