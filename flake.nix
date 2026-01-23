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
			in {
				devShells.default = pkgs.mkShell {
					packages = with pkgs; [
						zig_0_15
						sqlite
						sqlite-vec
						pcre2
						pkg-config
					];
					shellHook = ''
						export CODESCAN_SQLITE_VEC_PATH="${pkgs.sqlite-vec}/lib/vec0.dylib"
						export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
						export ZIG_LOCAL_CACHE_DIR="$PWD/zig-cache"
					'';
				};
			}
		);
}
