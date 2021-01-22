#!/usr/bin/env zsh

#
# Builds GCC and binutils for exclusively building kernels
#
# Modified by @kdrag0n for building compact toolchains.
# Thanks to Nathan Chancellor for the original bldgcc script:
# https://github.com/nathanchance/scripts/blob/master/funcs/bldgcc
#
# Example usage:
# $ bldgcc aarch64-elf arm-eabi
#
# By default (when no arguments are passed), the script will build AArch64 and
# AArch32 toolchains that target bare-metal systems. This results in compressed
# kernel images that are approximately 1 MiB smaller than those built by
# Linux-targeted toolchains.
#
# By default, the script will contain everything to a 'gcc' folder in ${PWD}.
# To change where that gcc folder is, either 'export TC_FOLDER=<value>' or
# 'TC_FOLDER=<value> bldgcc'.
#
# By default, the GCC and binutils versions will be the latest available.
# To change the versions, either 'export GCC_VERSION=<value> BINUTILS_VERSION=<value>'
# or 'GCC_VERSION=<value> BINUTILS_VERSION=<value> bldgcc'.
#
# The possible versions can be found here:
# https://mirrors.kernel.org/gnu/gcc/
# https://mirrors.kernel.org/gnu/binutils/
#
# This script is designed to build release versions of this software, not development
# versions. If you want to do that, it's not hard to modify this script to do that or
# use https://github.com/USBhost/build-tools-gcc
#

# Constants
LATEST_STABLE_GCC="9.2.0"
LATEST_STABLE_BINUTILS="2.32"

# Prints an error in bold red
function err() {
    echo
    echo "\e[1;31m$@\e[0m"
    echo
}

# Prints an error in bold red and exits the script
function die() {
    err "$@"
    builtin exit 1
}

# Shows an informational message
function msg() {
    echo -e "\e[1;32m$@\e[0m"
}

# Find the path of a shared library
function find_lib() {
    ldconfig -p | rg lib"$1"'\.so\.' | cut -d" " -f4 | head -n1
}

# Builds GCC and binutils for exclusively building kernels (bare-metal target)
function bldgcc() {
    local build_opts=("--toolchain")
    local targets=()

    # Get parameters
    [[ $# -eq 0 ]] && targets+=("aarch64-elf" "arm-eabi")
    while (( $# )); do
        case "$1" in
            "--binutils"|"--gcc"|"--toolchain") build_opts=("$1") ;;
            "all") targets+=("aarch64-elf" "arm-eabi") ;;
            "arm"|"arm64"|"powerpc"|"powerpc64"|"s390"|"x86_64"|*-*eabi*|*-elf|*-none|*-aout|*-rtems*|*-linux*) targets+=("$1") ;;
        esac
        shift
    done

    # Create directories
    local gcc_dir="${TC_FOLDER:=$PWD}/gcc"
    local scripts_dir="$gcc_dir/build"
    mkdir -p "$gcc_dir"

    # Download build scripts
    msg "Downloading build scripts..."
    [[ ! -d "$scripts_dir" ]] && git -C "$gcc_dir" clone "git://git.infradead.org/users/segher/buildall.git" build
    cd "$scripts_dir" || die "buildall clone failed!"

    # Download GCC
    [[ -z "$GCC_VERSION" ]] && GCC_VERSION="$LATEST_STABLE_GCC"
    local gcc_src="gcc-$GCC_VERSION"

    msg "Downloading GCC $GCC_VERSION..."

    if [[ "$GCC_VERSION" == "latest" ]]; then
        # Always update source
        rm -fr "$gcc_src"
        curl -LSs "https://github.com/gcc-mirror/gcc/archive/master.tar.gz" | pv - | tar -xzf -
        mv gcc-master "$gcc_src"
    else
        [[ ! -d "$gcc_src" ]] && curl -LSs "https://mirrors.kernel.org/gnu/gcc/$gcc_src/$gcc_src.tar.xz" | pv - | tar -xJf -
    fi

    # Download binutils
    [[ -z "$BINUTILS_VERSION" ]] && BINUTILS_VERSION="$LATEST_STABLE_BINUTILS"
    local binutils_src="binutils-$BINUTILS_VERSION"
    msg "Downloading binutils $BINUTILS_VERSION..."
    [[ ! -d "$binutils_src" ]] && curl -LSs "https://mirrors.kernel.org/gnu/binutils/$binutils_src.tar.xz" | tar -xJf -

    # Create timert
    msg "Compiling visual timer program..."
    [[ ! -f timert ]] && make -j"$(nproc)"

    # Build the toolchains
    for target in "${targets[@]}"; do
        echo

        # Create config
        local tc_prefix="$gcc_dir/$target-$GCC_VERSION"
        cat <<EOF > config
BINUTILS_SRC="$PWD/$binutils_src"
CHECKING=release
ECHO=/bin/echo
GCC_SRC="$PWD/$gcc_src"
MAKEOPTS=-j$(nproc)
PREFIX="$tc_prefix"
EXTRA_BINUTILS_CONF="--enable-lto --enable-gold --enable-deterministic-archives --enable-plugins --enable-relro --disable-gdb"
EXTRA_GCC_CONF="--with-isl --enable-lto --enable-plugin"
EOF

        # Clean up previous artifacts, can cause a false failure
        rm -rf "$target" "$tc_prefix"

        # Build toolchain
        msg "Building $target toolchain..."
        ./build "${build_opts[@]}" "$target"

        # Bundle libraries
        local isl_path="$(find_lib isl)"
        local gmp_path="$(find_lib gmp)"
        local mpc_path="$(find_lib mpc)"
        local mpfr_path="$(find_lib mpfr)"
        local libs=("$isl_path" "$gmp_path" "$mpc_path" "$mpfr_path")
        local lib_regex="(?:"
        local lib_regex_first=1

        msg "Copying libraries for $target toolchain..."
        for lib in "${libs[@]}"; do
            # Copy library
            echo "  - $lib"
            cp -L "$lib" "$tc_prefix/lib/"

            # Append library to regex
            [[ "$lib_regex_first" -eq 0 ]] && lib_regex+="|" || lib_regex_first=0
            lib_regex+="$(basename "$lib")"
        done

        # Conclude library regex
        lib_regex+=")"

        # Strip toolchains executables and set library rpaths
        # These are done in one step to save time as they iterate through the same files
        msg "Stripping $target toolchain and setting library load paths..."
        for exe in $(fd . "$tc_prefix" -x file | rg "ELF .+ interpreter" | awk '{print $1}'); do
            # Strip last character (':') from filename
            exe="${exe: : -1}"

            # Strip executable
            echo "  - strip: $exe"
            strip "$exe"

            # Set executable rpath if necessary
            if readelf -d "$exe" | rg -q "$lib_regex"; then
                echo "  - rpath: $exe"
                local rel_lib_path="$(realpath --relative-to="$exe" "$tc_prefix/lib")"
                patchelf --set-rpath '$ORIGIN/'"$rel_lib_path" "$exe"
            fi
        done

        # Print success message
        msg "Finished building $target toolchain!"
        echo "Path: $tc_prefix"
    done
}

bldgcc "$@"