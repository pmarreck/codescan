# Disposable projects contain the real wrapper and its verification helpers.
copy_build_fixture() {
	mkdir -p "$1/scripts" || return "$?"
	cp "$root/build" "$1/build" || return "$?"
	cp "$root/scripts/ci-verify-release" "$root/scripts/ci-verify-macos-arm64" "$1/scripts/"
}

# Text products exercise publication effects through a controlled reader port.
# The independently built native product must use the actual file reader.
file() {
	[ "$#" -eq 3 ] && [ "$1" = -b ] && [ "$2" = -- ] || return 64
	if [ "${BUILD_REAL_HEADER:-0}" -eq 1 ]; then command file "$@"; return "$?"; fi
	[ "${BUILD_HEADER_STATUS:-0}" -eq 0 ] || return "$BUILD_HEADER_STATUS"
	if [ -n "${BUILD_HEADER:-}" ]; then printf '%s\n' "$BUILD_HEADER"; return 0; fi
	case "$(uname -s)/$(uname -m)" in
		Linux/x86_64) printf '%s\n' 'ELF 64-bit LSB executable, x86-64, statically linked' ;;
		Linux/aarch64) printf '%s\n' 'ELF 64-bit LSB executable, ARM aarch64, statically linked' ;;
		Darwin/arm64) printf '%s\n' 'Mach-O 64-bit arm64 executable' ;;
		*) return 69 ;;
	esac
}
export -f file
