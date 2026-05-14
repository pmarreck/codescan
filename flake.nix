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

				# Pre-fetch Zig build.zig.zon dependencies for sandboxed builds
				sqlite-vec-src = pkgs.fetchgit {
					url = "https://github.com/pmarreck/sqlite-vec.git";
					rev = "742ac1607d5490c71758c9fde80820387391910d";
					hash = "sha256-CFZAditwPGoWpAK7AG8BaxksfxjEzyGdlMvuZPsJ7CQ=";
				};
				pcre2-src = pkgs.fetchgit {
					url = "https://github.com/pmarreck/pcre2.git";
					rev = "8fb017d8c41587a3eb3ac165b6e743d318c8fcfe";
					hash = "sha256-ru0tyw/GkB0D89ZHMhy+NsrbRPwZJoF5KwOJu7BW24c=";
					fetchSubmodules = true;
				};

				# Create a directory matching Zig's package cache layout
				# so we can pass it via --system to avoid network fetches
				zigPkgCache = pkgs.linkFarm "zig-pkg-cache" [
					{
						name = "sqlite_vec-0.1.7-alpha.2-4Cdt0OvwBACYsEQvfmbSw0sUHuXhcwD5PgjGyslHXU2q";
						path = sqlite-vec-src;
					}
					{
						name = "pcre2-10.47.0-S7QTbjnVMgAEncX1a_JtH4G6BgDWzC1tCMvL-KOMrM8b";
						path = pcre2-src;
					}
				];
			in {
				packages.default = pkgs.stdenv.mkDerivation {
					pname = "codescan";
					version = "0.1.0";

					src = ./.;

					nativeBuildInputs = [ pkgs.zig_0_16 ];

					dontConfigure = true;
					dontFixup = true;

					buildPhase = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
						mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

						zig build \
							--system ${zigPkgCache} \
							-Doptimize=ReleaseFast \
							--color off
					'';

					installPhase = ''
						mkdir -p $out/bin
						cp zig-out/bin/codescan $out/bin/
					'';

					meta = with pkgs.lib; {
						description = "Semantic code search powered by embeddings and tree-sitter";
						license = licenses.mit;
						platforms = platforms.unix;
						mainProgram = "codescan";
					};
				};

				devShells.default = pkgs.mkShell {
					packages = with pkgs; [
						zig_0_16
						jq
						luajit
						luajitPackages.cjson
					];
					shellHook = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export ZIG_GLOBAL_CACHE_DIR="$HOME/.cache/zig"
						export ZIG_LOCAL_CACHE_DIR="$PWD/zig-cache"
						export NIX_CFLAGS_COMPILE=""
					'';
				};
			}
		);
}
