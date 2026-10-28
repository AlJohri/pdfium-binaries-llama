#!/bin/bash -eux

IS_DEBUG=${PDFium_IS_DEBUG:-false}
OS=${PDFium_TARGET_OS:?}
TARGET_CPU=${PDFium_TARGET_CPU:?}
VERSION=${PDFium_VERSION:-}
PATCHES="$PWD/patches"
BUILD_TYPE=${PDFium_BUILD_TYPE:-shared}

SOURCE=${PDFium_SOURCE_DIR:-pdfium}
BUILD=${PDFium_BUILD_DIR:-pdfium/out}

STAGING="$PWD/staging"
STAGING_BIN="$STAGING/bin"
STAGING_LIB="$STAGING/lib"

mkdir -p "$STAGING"
rm -rf "$STAGING"/*
mkdir -p "$STAGING_LIB"

case "$BUILD_TYPE" in
  shared)
    CMAKE_CONFIG_FILE="PDFiumConfig.cmake"
    ;;
  static)
    CMAKE_CONFIG_FILE="PDFiumStaticConfig.cmake"
    ;;
esac
sed "s/#VERSION#/${VERSION:-0.0.0.0}/" <"$PATCHES/$CMAKE_CONFIG_FILE" >"$STAGING/PDFiumConfig.cmake"

cp LICENSE "$STAGING"
cat >>"$STAGING/LICENSE" <<END

This package also includes third-party software. See the licenses/ directory for their respective licenses.
END

cp "$BUILD/args.gn" "$STAGING"
cp -R "$SOURCE/public" "$STAGING/include"
rm -f "$STAGING/include/DEPS"
rm -f "$STAGING/include/README"
rm -f "$STAGING/include/PRESUBMIT.py"

# llamaparse: with pdf_use_mimalloc the allocator lives entirely inside the
# library. Fail the build if any allocator symbol (mimalloc, operator
# new/delete, libc malloc family) leaks into the export table -- a host that
# bound to one of these could free our memory with its own allocator.
verify_allocator_exports() {
  local lib="$1"
  # Only meaningful when mimalloc is linked in. Builds without it (32-bit,
  # ppc64, ...) export libc++'s own operator new/delete exactly as they always
  # did; that is not a leak of ours, so leave those export tables alone.
  if ! grep -q '^pdf_use_mimalloc = true' "$BUILD/args.gn"; then
    echo "allocator export check skipped: pdf_use_mimalloc is off for this build"
    return 0
  fi
  local tools="$SOURCE/third_party/llvm-build/Release+Asserts/bin"
  local exports
  case "$OS-$lib" in
    *.a) exports=$("$tools/llvm-nm" --defined-only --extern-only --format=just-symbols "$lib" | grep -v -e ":$" -e "^$") ;;
    linux-*|android-*) exports=$("$tools/llvm-nm" -D --defined-only "$lib" | awk '{print $3}') ;;
    mac-*|ios-*) exports=$("$tools/llvm-nm" -gU "$lib" | awk '{print $3}') ;;
    win-*)
      # The Windows LLVM package ships no llvm-readobj; read the PE export
      # table directly (stdlib python, see steps/pe_exports.py).
      local py
      py=$(command -v python3 || command -v python)
      exports=$("$py" "$(dirname "${BASH_SOURCE[0]}")/pe_exports.py" "$lib")
      ;;
    *) return 0 ;;
  esac
  # Self-check: a gate that read nothing must fail, not pass. Every PDFium
  # build exports FPDF_InitLibrary.
  if ! printf '%s\n' "$exports" | grep -qE '^_?FPDF_InitLibrary$'; then
    echo "ERROR: could not read the export table of $lib (FPDF_InitLibrary missing)" >&2
    exit 1
  fi
  local leaked
  leaked=$(printf '%s\n' "$exports" | grep -E '^_{0,2}(mi_|Zn|Zd|malloc$|free$|calloc$|realloc$|posix_memalign$|aligned_alloc$)' || true)
  if [ -n "$leaked" ]; then
    echo "ERROR: allocator symbols exported from $lib:" >&2
    echo "$leaked" >&2
    exit 1
  fi
  echo "allocator export check passed: $lib ($(printf '%s\n' "$exports" | grep -c .) exports)"
}

# A static archive exposes every global symbol of PDFium's bundled
# dependencies (abseil, ICU, libjpeg, freetype, ...), which collide with the consumer's
# own copies, and, with mimalloc, a global operator new/delete that would
# replace the host's. Merge the archive into one relocatable object and
# keep only the functions the public headers declare global, matching what the
# shared library exports.
hide_internal_symbols() {
  local lib="$1"
  local tools="$SOURCE/third_party/llvm-build/Release+Asserts/bin"
  local prefix=""
  case "$OS" in
    mac|ios) prefix="_" ;;
  esac
  local work
  work=$(mktemp -d)
  python3 "$(dirname "${BASH_SOURCE[0]}")/public_symbols.py" "$STAGING/include" \
    | sed "s/^/$prefix/" >"$work/declared.txt"
  "$tools/llvm-nm" --defined-only --extern-only --format=just-symbols "$lib" \
    | grep -x -F -f "$work/declared.txt" | sort -u >"$work/public.txt"
  if ! grep -qx "${prefix}FPDF_InitLibrary" "$work/public.txt"; then
    echo "ERROR: no public symbols found in $lib (FPDF_InitLibrary missing)" >&2
    exit 1
  fi
  case "$OS" in
    linux|android)
      # --whole-archive pulls in every member, so drop the sections that no
      # public function reaches; the consumer's linker no longer can.
      sed 's/^/--undefined=/' "$work/public.txt" >"$work/roots.rsp"
      "$tools/ld.lld" -r --gc-sections "@$work/roots.rsp" --whole-archive "$lib" -o "$work/pdfium.o"
      "$tools/llvm-objcopy" --keep-global-symbols="$work/public.txt" "$work/pdfium.o"
      ;;
    mac|ios)
      # The merged object keeps the platform, deployment target and SDK that
      # the archive was built for.
      local member platform="" minos="" sdk=""
      for member in $("$tools/llvm-ar" t "$lib"); do
        (cd "$work" && "$tools/llvm-ar" x "$lib" "$member")
        read -r platform minos sdk < <(xcrun vtool -show-build "$work/$member" 2>/dev/null \
          | awk '$1 == "platform" { p = $2 } $1 == "minos" { m = $2 } $1 == "sdk" { s = $2 }
                 END { print p, m, s }')
        rm -f "$work/$member"
        [ -n "$minos" ] && break
      done
      case "$platform" in
        MACOS) platform=macos ;;
        IOS) platform=ios ;;
        IOSSIMULATOR) platform=ios-simulator ;;
        MACCATALYST) platform=mac-catalyst ;;
        *)
          echo "ERROR: unknown platform '$platform' in $lib" >&2
          exit 1
          ;;
      esac
      [ "$sdk" == "n/a" ] && sdk="$minos"
      local arch=arm64
      [ "$TARGET_CPU" == "x64" ] && arch=x86_64
      xcrun ld -r -arch "$arch" -platform_version "$platform" "$minos" "$sdk" \
        -all_load "$lib" -exported_symbols_list "$work/public.txt" -o "$work/pdfium.o"
      ;;
  esac
  rm "$lib"
  "$tools/llvm-ar" rcs "$lib" "$work/pdfium.o"
  rm -rf "$work"
}

case "$OS-$BUILD_TYPE" in
  android-shared|linux-shared)
    mv "$BUILD/libpdfium.so" "$STAGING_LIB"
    verify_allocator_exports "$STAGING_LIB/libpdfium.so"
    ;;

  android-static|linux-static|mac-static|ios-static)
    mv "$BUILD/obj/libpdfium.a" "$STAGING_LIB"
    hide_internal_symbols "$STAGING_LIB/libpdfium.a"
    verify_allocator_exports "$STAGING_LIB/libpdfium.a"
    ;;

  mac-shared|ios-shared)
    mv "$BUILD/libpdfium.dylib" "$STAGING_LIB"
    verify_allocator_exports "$STAGING_LIB/libpdfium.dylib"
    ;;

  emscripten-*)
    mv "$BUILD/obj/libpdfium.a" "$STAGING_LIB"
    rm -rf "$STAGING/include/cpp"
    rm "$STAGING/PDFiumConfig.cmake"
    ;;

  wasi-*)
    mv "$BUILD/obj/libpdfium.a" "$STAGING_LIB"
    # Ship WASI sysroot libraries so consumers can resolve all C/C++ runtime
    # symbols at link time. Without these, libc/libc++ functions appear as
    # unresolved "env::" imports in the final .wasm binary.
    #
    # In WASI SDK 24+:
    #   - C libs (libc, wasi-emulated-*) are under $WASI_SYSROOT/lib/wasm32-wasip1/
    #   - C++ libs (libc++, libc++abi) are under $WASI_SDK_PATH/lib/wasm32-wasip1/
    SYSROOT_LIB="${WASI_SYSROOT:?}/lib/wasm32-wasip1"
    cp "$SYSROOT_LIB/libc.a"                    "$STAGING_LIB"
    cp "$SYSROOT_LIB/libc++.a"                  "$STAGING_LIB"
    cp "$SYSROOT_LIB/libc++abi.a"               "$STAGING_LIB"
    cp "$SYSROOT_LIB/libwasi-emulated-mman.a"   "$STAGING_LIB"
    cp "$SYSROOT_LIB/libwasi-emulated-signal.a" "$STAGING_LIB"
    # libsetjmp defines the `__c_longjmp` wasm exception tag referenced by
    # any object compiled with `-mllvm -wasm-enable-sjlj` (libjpeg's error
    # handler, FreeType's sfnt loader). Without it, the link fails with
    # `undefined symbol: __c_longjmp` once consumers stop passing
    # `--allow-undefined` to wasm-ld (Rust 1.96+ default).
    cp "$SYSROOT_LIB/libsetjmp.a"               "$STAGING_LIB"
    ;;

  win-shared)
    mv "$BUILD/pdfium.dll.lib" "$STAGING_LIB"
    mkdir -p "$STAGING_BIN"
    mv "$BUILD/pdfium.dll" "$STAGING_BIN"
    verify_allocator_exports "$STAGING_BIN/pdfium.dll"
    [ "$IS_DEBUG" == "true" ] && mv "$BUILD/pdfium.dll.pdb" "$STAGING_BIN"
    ;;

  win-static)
    mv "$BUILD/obj/pdfium.lib" "$STAGING_LIB"
    ;;
esac

if [ -n "$VERSION" ]; then
  cat >"$STAGING/VERSION" <<END
MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)
BUILD=$(echo "$VERSION" | cut -d. -f3)
PATCH=$(echo "$VERSION" | cut -d. -f4)
END
fi
