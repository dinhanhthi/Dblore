#!/bin/bash

# Build the SQL Server plugin's third-party C libraries: FreeTDS db-lib over OpenSSL, as arm64
# static libraries for macOS 14.0 (the app's minimum), from source tarballs pinned by URL and
# SHA-256 below. Run from anywhere; everything goes into the gitignored dist/ of the repo.
#
# Output layout (dist/deps/sqlserver/):
#   include/        FreeTDS headers (sybdb.h, sybfront.h, ...) and OpenSSL headers (openssl/*.h)
#   lib/            libsybdb.a (FreeTDS db-lib), libssl.a, libcrypto.a
#   versions.txt    KEY=value lines: library versions, source URLs and SHA-256s
#   .stamp          written last; a rebuild is skipped while it matches this script and the libs exist
#   src/            the downloaded tarballs (checked against the pinned SHA-256 before extraction)
#   build/          extracted sources and install stages (scratch)
#
# The bundle links them statically with -liconv (the system iconv). Licensing: FreeTDS is
# LGPL; the plugin source is public (AGPL-3.0 repo) and this script pins the exact FreeTDS
# source tarball, so the bundle can be relinked against a modified FreeTDS.
#
# FreeTDS publishes only MD5 files; the FreeTDS SHA-256 below was computed from a tarball whose
# MD5 matched the published one. OpenSSL's SHA-256 is the one published with its release.

set -euo pipefail

FREETDS_VERSION="1.5.21"
FREETDS_URL="https://www.freetds.org/files/stable/freetds-$FREETDS_VERSION.tar.bz2"
FREETDS_SHA256="76e042f3c42579846a70ae19694bb8fb0bc8f6d76ac01572cfef51a37619bb3c"

OPENSSL_VERSION="3.5.9"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"

MIN_MACOS="14.0"

# Install prefixes that do not exist on any Mac: they are baked into the libraries (OpenSSL's
# OPENSSLDIR / MODULESDIR, FreeTDS's freetds.conf location), so no config file is ever found
# there and no local build path ships in the bundle. Installs go through DESTDIR into build/.
OPENSSL_PREFIX="/nonexistent/dblore/openssl"
FREETDS_PREFIX="/nonexistent/dblore/freetds"

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/../../../.." && pwd)"
OUT="$REPO_ROOT/dist/deps/sqlserver"
SRC_DIR="$OUT/src"
BUILD_DIR="$OUT/build"
STAMP="$OUT/.stamp"
OUT_LIBS=(libsybdb.a libssl.a libcrypto.a)

die() {
  echo "build-deps: $*" >&2
  exit 1
}

# Toolchain only from the system and Xcode: no Homebrew pkg-config, OpenSSL or libiconv
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset CPATH C_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH CPPFLAGS CFLAGS LDFLAGS LIBS || true
export PKG_CONFIG_LIBDIR=""

SCRIPT_SHA256="$(shasum -a 256 "$SCRIPT_PATH" | awk '{print $1}')"
STAMP_TEXT="script=$SCRIPT_SHA256 freetds=$FREETDS_VERSION:$FREETDS_SHA256 openssl=$OPENSSL_VERSION:$OPENSSL_SHA256 minos=$MIN_MACOS arch=arm64"

outputs_exist() {
  local lib
  for lib in "${OUT_LIBS[@]}"; do
    [[ -f "$OUT/lib/$lib" ]] || return 1
  done
  [[ -f "$OUT/include/sybdb.h" && -f "$OUT/include/openssl/ssl.h" && -f "$OUT/versions.txt" ]]
}

if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$STAMP_TEXT" ]] && outputs_exist; then
  echo "build-deps: up to date (FreeTDS $FREETDS_VERSION, OpenSSL $OPENSSL_VERSION) in $OUT"
  exit 0
fi

# A rebuild starts: the stamp goes first and comes back only after every check passed
rm -f "$STAMP"
rm -rf "$OUT/include" "$OUT/lib" "$OUT/versions.txt" "$BUILD_DIR"
mkdir -p "$SRC_DIR" "$BUILD_DIR"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Download (or reuse) a tarball and check it against its pinned SHA-256. A mismatch deletes the
# file and stops the build; a later run downloads it again.
fetch() {
  local url="$1" expected="$2" file actual
  file="$SRC_DIR/$(basename "$url")"
  if [[ ! -f "$file" ]]; then
    echo "build-deps: downloading $url"
    curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  actual="$(sha256_of "$file")"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$file"
    die "SHA-256 mismatch for $(basename "$file"): expected $expected, got $actual (file deleted)"
  fi
  echo "build-deps: $(basename "$file") SHA-256 OK"
}

# Extract a verified tarball into its own empty directory (bsdtar refuses absolute paths, ..
# and extraction through symlinks by default)
extract() {
  local file="$1" dest="$2"
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xf "$file" -C "$dest" --no-same-owner
}

fetch "$OPENSSL_URL" "$OPENSSL_SHA256"
fetch "$FREETDS_URL" "$FREETDS_SHA256"

extract "$SRC_DIR/$(basename "$OPENSSL_URL")" "$BUILD_DIR/openssl-src"
extract "$SRC_DIR/$(basename "$FREETDS_URL")" "$BUILD_DIR/freetds-src"
OPENSSL_SRC="$BUILD_DIR/openssl-src/openssl-$OPENSSL_VERSION"
FREETDS_SRC="$BUILD_DIR/freetds-src/freetds-$FREETDS_VERSION"
[[ -d "$OPENSSL_SRC" && -d "$FREETDS_SRC" ]] || die "unexpected tarball layout"

# Target macOS 14.0 on arm64, not the build host's macOS: autoconf and Configure would
# otherwise probe the host SDK's newest libc. A call to an API newer than 14.0 without an
# availability check fails the build.
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
CC="$(xcrun --sdk macosx -f clang)"
export CC
TARGET_FLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS -isysroot $SDKROOT"
AVAILABILITY_FLAGS="-Werror=unguarded-availability-new"
JOBS="$(sysctl -n hw.ncpu)"

# OpenSSL: static libssl / libcrypto, providers built in (no-module), no config read from disk
OPENSSL_STAGE="$BUILD_DIR/openssl-stage"
OPENSSL_ROOT="$OPENSSL_STAGE$OPENSSL_PREFIX"
echo "build-deps: building OpenSSL $OPENSSL_VERSION"
(
  cd "$OPENSSL_SRC"
  CFLAGS="$TARGET_FLAGS -O3 $AVAILABILITY_FLAGS" LDFLAGS="$TARGET_FLAGS" \
    ./Configure darwin64-arm64-cc no-shared no-module no-tests no-docs \
    --prefix="$OPENSSL_PREFIX" --openssldir="$OPENSSL_PREFIX/ssl" --libdir=lib
  make -j"$JOBS"
  make install_sw DESTDIR="$OPENSSL_STAGE"
)
[[ -f "$OPENSSL_ROOT/lib/libssl.a" && -f "$OPENSSL_ROOT/lib/libcrypto.a" ]] \
  || die "OpenSSL install is missing libssl.a or libcrypto.a"

# FreeTDS: static db-lib over the OpenSSL just built, system iconv, no Kerberos (off unless
# --enable-krb5), no GnuTLS, no ODBC, apps, server or pool
FREETDS_STAGE="$BUILD_DIR/freetds-stage"
FREETDS_ROOT="$FREETDS_STAGE$FREETDS_PREFIX"
echo "build-deps: building FreeTDS $FREETDS_VERSION"
(
  cd "$FREETDS_SRC"
  ./configure \
    --prefix="$FREETDS_PREFIX" --sysconfdir="$FREETDS_PREFIX/etc" \
    --disable-shared --enable-static \
    --disable-odbc --disable-apps --disable-server --disable-pool \
    --without-libiconv-prefix \
    --with-openssl="$OPENSSL_ROOT" \
    OPENSSL_CFLAGS="-I$OPENSSL_ROOT/include" \
    OPENSSL_LIBS="-L$OPENSSL_ROOT/lib -lssl -lcrypto" \
    CFLAGS="$TARGET_FLAGS -O2 $AVAILABILITY_FLAGS" \
    LDFLAGS="$TARGET_FLAGS"
  grep -q '^#define HAVE_OPENSSL 1' include/config.h || die "FreeTDS configure did not enable OpenSSL"
  if grep -q '^#define HAVE_GNUTLS 1' include/config.h; then die "FreeTDS configure enabled GnuTLS"; fi
  if grep -q '^#define ENABLE_KRB5 1' include/config.h; then die "FreeTDS configure enabled Kerberos"; fi
  grep -q '^#define HAVE_ICONV 1' include/config.h || die "FreeTDS configure found no system iconv"
  if grep -qE -- '-[IL] ?/(opt/homebrew|usr/local)' config.status; then
    die "FreeTDS configure picked up a Homebrew or /usr/local path"
  fi
  make -j"$JOBS"
  make install DESTDIR="$FREETDS_STAGE"
)
[[ -f "$FREETDS_ROOT/lib/libsybdb.a" ]] || die "FreeTDS install is missing libsybdb.a"

mkdir -p "$OUT/include" "$OUT/lib"
cp -R "$OPENSSL_ROOT/include/openssl" "$OUT/include/"
cp "$FREETDS_ROOT"/include/*.h "$OUT/include/"
cp "$OPENSSL_ROOT/lib/libssl.a" "$OPENSSL_ROOT/lib/libcrypto.a" "$FREETDS_ROOT/lib/libsybdb.a" "$OUT/lib/"

# Every object must be arm64 and built for macOS 14.0 exactly
for lib in "${OUT_LIBS[@]}"; do
  [[ "$(lipo -archs "$OUT/lib/$lib")" == "arm64" ]] || die "$lib is not arm64 only"
  minos="$(otool -l "$OUT/lib/$lib" | awk '$1 == "minos" {print $2}' | sort -u | tr '\n' ' ')"
  [[ "$minos" == "$MIN_MACOS " ]] || die "$lib objects have minos '$minos', expected $MIN_MACOS"
done

cat >"$OUT/versions.txt" <<EOF
FREETDS_VERSION=$FREETDS_VERSION
FREETDS_URL=$FREETDS_URL
FREETDS_SHA256=$FREETDS_SHA256
OPENSSL_VERSION=$OPENSSL_VERSION
OPENSSL_URL=$OPENSSL_URL
OPENSSL_SHA256=$OPENSSL_SHA256
MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
EOF

printf '%s' "$STAMP_TEXT" >"$STAMP"
echo "build-deps: done (FreeTDS $FREETDS_VERSION, OpenSSL $OPENSSL_VERSION) in $OUT"
for lib in "${OUT_LIBS[@]}"; do
  echo "  lib/$lib $(stat -f %z "$OUT/lib/$lib") bytes"
done
