#!/usr/bin/env bash
# Builds OpenSSL 3.5 LTS as a static autobuild package for Vulkanstorm.
#
# Changes against secondlife/3p-openssl (1.1.1w):
#   - source: the signed OpenSSL release tarball, SHA-256 pinned below, instead
#     of the git submodule (the tarball is what was verified against the
#     release signature; see README.md);
#   - Configure adds 'no-module': the legacy provider (RC4, needed for the
#     viewer's bin_conf.dat) is compiled into libcrypto instead of being a
#     legacy.dll/legacy.so the viewer would have to stage and locate;
#   - Windows keeps OpenSSL's own /nologo /W3 /wd4090, which a CFLAGS
#     environment variable otherwise replaces, and uses jom when present;
#   - a smoke test runs the built openssl binary: the legacy provider must be
#     built in and active, and RC4 must give the known answer through it.
# Everything else (zlib-ng linkage, threads, static libraries, the layout of
# stage/) is as in LL's script.

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unreferenced environment variables
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

OPENSSL_VERSION="3.5.9"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/{debug,release}/*.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

sha256_of ()
{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# The built openssl binary ($1) must list the legacy provider as active
# (compiled into libcrypto by 'no-module') and give RC4's known answer
# through it: RC4, key 00..0f, "vulkanstorm" (checked against a textbook RC4).
smoke_test ()
{
    local exe="$1"
    "$exe" version -a
    local providers
    providers="$("$exe" list -providers -provider default -provider legacy | tr -d '\r')"
    echo "$providers"
    echo "$providers" | grep -A3 '^  legacy' | grep -q 'status: active' \
        || { echo "legacy provider is not built in" 1>&2; exit 1; }
    local rc4
    rc4="$(printf 'vulkanstorm' | "$exe" enc -rc4 -K 000102030405060708090a0b0c0d0e0f \
               -provider legacy -provider default | od -An -tx1 | tr -d ' \n\r')"
    [ "$rc4" = "9fe92c92268c6ab869a9fa" ] || { echo "RC4 known-answer test failed: $rc4" 1>&2; exit 1; }
}

top="$(pwd)"
stage="$top/stage"

[ -f "$stage"/packages/include/zlib-ng/zlib.h ] || \
{ echo "You haven't yet run 'autobuild install'." 1>&2; exit 1; }

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

# Fetch (or reuse) the release tarball and check it against the pinned digest.
# OPENSSL_TARBALL may name an already downloaded copy; it is checked the same way.
mkdir -p "$top/dl"
tarball="$top/dl/openssl-${OPENSSL_VERSION}.tar.gz"
if [ -n "${OPENSSL_TARBALL:-}" ]; then
    cp -f "$OPENSSL_TARBALL" "$tarball"
elif [ ! -f "$tarball" ]; then
    curl -sSfL --retry 3 -o "$tarball" "$OPENSSL_URL"
fi
actual_sha256="$(sha256_of "$tarball")"
if [ "$actual_sha256" != "$OPENSSL_SHA256" ]; then
    echo "SHA-256 mismatch for $tarball: $actual_sha256" 1>&2
    exit 1
fi

OPENSSL_SOURCE_DIR="$top/openssl-${OPENSSL_VERSION}"
rm -rf "$OPENSSL_SOURCE_DIR"
tar -xzf "$tarball" -C "$top"

# autobuild reads version_file from the build directory
cp -f "$top/VERSION.txt" "$stage/VERSION.txt"

pushd "$OPENSSL_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        windows*)
            # configure won't work with VC-* builds undex cygwin's perl, use window's one
            export PATH="/c/Strawberry/perl/bin:$PATH"
            # NASM for the assembler modules: winget's per-user install or the machine-wide one
            for nasmdir in "${LOCALAPPDATA:-}/bin/NASM" "C:/Program Files/NASM"; do
                if [ -n "$nasmdir" ] && [ -x "$(cygpath -u "$nasmdir")/nasm.exe" ]; then
                    export PATH="$(cygpath -u "$nasmdir"):$PATH"
                    break
                fi
            done

            load_vsvars

            mkdir -p "$stage/lib/release"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                targetname=VC-WIN32
            else
                # might require running vcvars64.bat from VS studio
                targetname=VC-WIN64A
            fi

            # Set CFLAGS directly, rather than on the Configure command line.
            # Configure promises to pass through -switches, but is completely
            # confounded by /switches. If you change /switches to -switches
            # using bash string magic, Configure does pass them through --
            # only to have cl.exe ignore them with extremely verbose warnings!
            # CFLAGS can accept /switches and correctly pass them to cl.exe.
            # CFLAGS replaces the target's own CFLAGS, so those (/nologo /W3
            # /wd4090) go in front. /MD from LL_BUILD_RELEASE matters: with
            # OpenSSL's default /MT, openssl.exe does not link against the /MD
            # zlib-ng package (__imp__aligned_malloc unresolved).
            opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"
            export CFLAGS="/nologo /W3 /wd4090 $plainopts"
            export CXXFLAGS="$opts"

            perl Configure "$targetname" zlib no-zlib-dynamic threads no-shared no-module -DUNICODE -D_UNICODE -FS \
                --with-zlib-include="$(cygpath -w "$stage/packages/include/zlib-ng")" \
                --with-zlib-lib="$(cygpath -w "$stage/packages/lib/release/zlib.lib")"

            if command -v jom >/dev/null 2>&1; then
                make_tool=jom
            else
                make_tool=nmake
            fi
            "$make_tool" -nologo

            smoke_test "apps/openssl.exe"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                HARNESS_JOBS="${AUTOBUILD_CPU_COUNT:-4}" "$make_tool" -nologo test
            fi

            cp -a {libcrypto,libssl}.lib "$stage/lib/release"

            # Publish headers
            mkdir -p "$stage/include/openssl"
            cp -a include/openssl/*.h "$stage/include/openssl"
        ;;

        darwin*)
            # Force static linkage by moving .dylibs out of the way
            trap restore_dylibs EXIT
            for dylib in "$stage/packages/lib"/{debug,release}/*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_DEPLOY_TARGET}

            for arch in x86_64 arm64 ; do
                opts="${TARGET_OPTS:-$LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $opts)"
                ld_opts="-Wl,-headerpad_max_install_names"

                # It seems to be important to Configure to pass (e.g.)
                # "-iwithsysroot=/some/path" instead of just glomming them on
                # as separate arguments. So make a pass over $opts, collecting
                # switches with args in that form into a bash array.
                packed=()
                pack=()
                function flush {
                    local IFS="="
                    # Flush 'pack' array to the next entry of 'packed'.
                    # ${pack[*]} concatenates all of pack's entries into a single
                    # string separated by the first char from $IFS.
                    packed+=("${pack[*]:-}")
                    pack=()
                }
                for opt in $cc_opts $ld_opts
                do
                if [ "x${opt#-}" != "x$opt" ]
                then
                    # 'opt' does indeed start with dash.
                    flush
                fi
                # append 'opt' to 'pack' array
                pack+=("$opt")
                done
                # When we exit the above loop, we've got one more pending entry in
                # 'pack'. Flush that too.
                flush
                # We always have an extra first entry in 'packed'. Get rid of that.
                unset packed[0]

                mkdir -p "build_$arch"
                pushd "build_$arch"
                    CFLAGS="$cc_opts" \
                    CXXFLAGS="$opts" \
                    LDFLAGS="$ld_opts" \
                    ../Configure --release zlib no-zlib-dynamic threads no-shared no-module darwin64-"$arch"-cc \
                        --prefix="$stage" --libdir="lib/release/$arch" --openssldir="share" \
                        --with-zlib-include="$stage/packages/include/zlib-ng" \
                        --with-zlib-lib="$stage/packages/lib/release" \
                        "${packed[@]}"
                        make depend
                        make -j$AUTOBUILD_CPU_COUNT
                        # Avoid plain 'make install' because, at least on Yosemite,
                        # installing the man pages into the staging area creates problems
                        # due to the number of symlinks. Thanks to Cinder for suggesting
                        # this make target.
                        make install_sw

                        if [ "$arch" = "$(uname -m)" ]; then
                            smoke_test "apps/openssl"
                        fi

                        # conditionally run unit tests
                        if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                            HARNESS_JOBS="$AUTOBUILD_CPU_COUNT" make test
                        fi

                        make clean
                popd
            done

            # create stage structure
            mkdir -p "$stage/lib/release"

           # create fat libraries
            lipo -create -output ${stage}/lib/release/libcrypto.a ${stage}/lib/release/x86_64/libcrypto.a ${stage}/lib/release/arm64/libcrypto.a
            lipo -create -output ${stage}/lib/release/libssl.a ${stage}/lib/release/x86_64/libssl.a ${stage}/lib/release/arm64/libssl.a
        ;;

        linux*)
            # Default target per AUTOBUILD_ADDRSIZE
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"
            opts="$(remove_cxxstd $opts)"

            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="${TARGET_CPPFLAGS:-}"
            fi

            # Force static linkage to libz by moving .sos out of the way
            trap restore_sos EXIT
            for solib in "${stage}"/packages/lib/debug/*.so* "${stage}"/packages/lib/release/*.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                targetname='linux-generic32'
            else
                targetname='linux-x86_64'
            fi

            # '--libdir' functions a bit different than usual.  Here it names
            # a part of a directory path, not the entire thing.  Same with
            # '--openssldir' as well.
            # "shared" means build shared and static, instead of just static.

            ./Configure zlib no-zlib-dynamic threads no-shared no-module "$targetname" "$opts" \
                --prefix="$stage" --libdir="lib/release" --openssldir="share" \
                --with-zlib-include="$stage/packages/include/zlib-ng" \
                --with-zlib-lib="$stage"/packages/lib/release/
            make depend
            make -j$AUTOBUILD_CPU_COUNT
            make install_sw

            smoke_test "apps/openssl"

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                HARNESS_JOBS="$AUTOBUILD_CPU_COUNT" make test
            fi

            make clean
        ;;
    esac
    mkdir -p "$stage/LICENSES"
    cp -a LICENSE.txt "$stage/LICENSES/openssl.txt"
popd

mkdir -p "$stage"/docs/openssl/
