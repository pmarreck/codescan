{
	description = "codescan";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = { self, nixpkgs, flake-utils }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs { inherit system; };
				sqlite-amalgamation = pkgs.fetchzip {
					url = "https://www.sqlite.org/2024/sqlite-amalgamation-3450300.zip";
					sha256 = "sha256-F50oTmmcPIl0AZJbsWAR3tbNAPV3pQLf+CNITzhmXfI=";
					stripRoot = true;
				};
			in {
				devShells.default = pkgs.mkShell {
					packages = with pkgs; [
						zig_0_15
						pcre2
					];
					shellHook = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
						export ZIG_LOCAL_CACHE_DIR="$PWD/zig-cache"
						export NIX_CFLAGS_COMPILE=""
						export C_INCLUDE_PATH="${pkgs.pcre2.dev}/include"
						export LIBRARY_PATH="${pkgs.pcre2.out}/lib"
					'';
				};
			}
		);
}
