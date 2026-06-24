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
					rev = "c9d3630f56637276829d9ab0c54b1116c6d3e2ef";
					hash = "sha256-9MBuzlHICNc0U4TIEEPd0gWAftxllXcU8bhilcaAh+k=";
				};
				pcre2-src = pkgs.fetchgit {
					url = "https://github.com/pmarreck/pcre2.git";
					rev = "873ecf6466a0ddf62facfffbd387213249db20bb";
					hash = "sha256-a37QL33zCTth7qMBtzwjBkUNjmku6kRa0rrz7oSAOxA=";
					fetchSubmodules = true;
				};

				# Create a directory matching Zig's package cache layout
				# so we can pass it via --system to avoid network fetches
				zigPkgCache = pkgs.linkFarm "zig-pkg-cache" [
					{
						name = "sqlite_vec-0.1.7-alpha.2-4Cdt0CTyBADFzDhhNOTSAUplRsfH1qs-DqwP6FwrZ641";
						path = sqlite-vec-src;
					}
					{
						name = "pcre2-10.47.0-S7QTbvnVMgDsA1ipkKNj5kVoEda9wcIuZYUpdrTuDaCh";
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

				# The check Garnix was missing: packages.default only COMPILES. This runs
				# the (now hermetic — no live Ollama/OpenAI) test suite AND smoke-execs the
				# binary, so a passing build can no longer hide broken or non-running code.
				checks.test = pkgs.stdenv.mkDerivation {
					pname = "codescan-test";
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
						# 1) actually RUN the suite (the part never wired into CI)
						zig build test --system ${zigPkgCache} --color off
						# 2) smoke-EXECUTE the built binary (catches runtime/loader regressions)
						zig build --system ${zigPkgCache} -Doptimize=ReleaseFast --color off
						./zig-out/bin/codescan --help >/dev/null
					'';
					installPhase = ''
						mkdir -p $out
						echo "tests passed and binary executes" > $out/result
					'';
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
