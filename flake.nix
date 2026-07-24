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

				grammarSource = owner: repo: rev: hash: pkgs.fetchFromGitHub {
					inherit owner repo rev hash;
				};
				grammar-fish = grammarSource "ram02z" "tree-sitter-fish"
					"f435b0bd772578c70e5d158b85267bb886316f88"
					"sha256-9an4YAz2QKC3yAJ5/tOfmqOJViGATz7+NhKuZpr4oC4=";
				grammar-nu = grammarSource "nushell" "tree-sitter-nu"
					"d694570aa26b53d0d642460a0430e8aa07dcbea0"
					"sha256-eWHAcV8bPCnL9y4PtPn6cJRylGQ2KMxCUoUGwDVigkg=";
				grammar-powershell = grammarSource "wharflab" "tree-sitter-powershell"
					"afb492d0d25f33636bbba89ab70cb4d160d8669a"
					"sha256-WVaLD53tLpUJq204qioVtrLmW/7HxvymNjhXxEmbJ+Y=";
				grammar-tcl = grammarSource "tree-sitter-grammars" "tree-sitter-tcl"
					"8f11ac7206a54ed11210491cee1e0657e2962c47"
					"sha256-JrGSHGolf7OhInxotXslw1QXxJscl+bXCxZPYJeBfTY=";
				grammar-fsharp = grammarSource "ionide" "tree-sitter-fsharp"
					"ac263e4baf76f407315ef71995cf778711548152"
					"sha256-xzWdwyHJnjKDBLgWqzuc0a27BlpQfN2ZWQ/hKpDyLV8=";
				grammar-elm = grammarSource "elm-tooling" "tree-sitter-elm"
					"e1e8fea161a1e66f3997855d316be2a43e4e956f"
					"sha256-6Vnn8lGCwuQlQFmmSXPF+JKwRIR9+YI8ybmm5oZBzfA=";
				grammar-gleam = grammarSource "gleam-lang" "tree-sitter-gleam"
					"cefbd6863983b4df3214b7934bde5e9ca63d5b7f"
					"sha256-j5FFZ/2HsCfMuJpDHJZ2pfYaFU6Rc3BjUrSeOi/89ZM=";
				grammar-scheme = grammarSource "6cdh" "tree-sitter-scheme"
					"c6cb7c7d7a04b3f5d999c28e2e9c0c31b2d50ece"
					"sha256-aFonUd15PJkQmz5lDJthtd1rU+8OXNknHDlgqH2s+OA=";
				grammar-commonlisp = grammarSource "tree-sitter-grammars" "tree-sitter-commonlisp"
					"32323509b3d9fe96607d151c2da2c9009eb13a2f"
					"sha256-cNGxZXoxhnXGo4yhMHDSjF/j43JNXg1ClpqN2xJgLQU=";
				grammar-sml = grammarSource "MatthewFluet" "tree-sitter-sml"
					"fd4b4955bb998262840ab8119885b3edf20ea75a"
					"sha256-umtQq0oIg6KAbj7eFZOLVWjTvCPy99MSB6Q9jr5vIsE=";
				grammar-wat = grammarSource "g-plane" "tree-sitter-wat"
					"e3769473b2d90643d8af500b5cfc2f25a674888a"
					"sha256-m0x3u1Uw/0ONxqiac5OvieyDYcYxkwvGbLrJOsTVoLg=";

				# One immutable root keeps build.zig independent of Nix's individual
				# store paths while preserving exact source provenance in this flake.
				grammarSources = pkgs.linkFarm "codescan-tree-sitter-grammars" [
					{ name = "fish"; path = "${grammar-fish}/src"; }
					{ name = "nu"; path = "${grammar-nu}/src"; }
					{ name = "powershell"; path = "${grammar-powershell}/src"; }
					{ name = "tcl"; path = "${grammar-tcl}/src"; }
					{ name = "fsharp"; path = grammar-fsharp; }
					{ name = "elm"; path = "${grammar-elm}/src"; }
					{ name = "gleam"; path = "${grammar-gleam}/src"; }
					{ name = "scheme"; path = "${grammar-scheme}/src"; }
					{ name = "commonlisp"; path = "${grammar-commonlisp}/src"; }
					{ name = "sml"; path = "${grammar-sml}/src"; }
					{ name = "wat"; path = "${grammar-wat}/src"; }
				];

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
						export CODESCAN_GRAMMAR_ROOT="${grammarSources}"
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
					nativeBuildInputs = [ pkgs.zig_0_16 pkgs.git ];
					dontConfigure = true;
					dontFixup = true;
					buildPhase = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export CODESCAN_GRAMMAR_ROOT="${grammarSources}"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
						mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
						# 1) actually RUN the suite (the part never wired into CI)
						zig build test-unit --system ${zigPkgCache} --color off
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
						git
						jq
						sqlite
						luajit
						luajitPackages.cjson
					];
					shellHook = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export CODESCAN_GRAMMAR_ROOT="${grammarSources}"
						export ZIG_GLOBAL_CACHE_DIR="''${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}"
						export ZIG_LOCAL_CACHE_DIR="''${ZIG_LOCAL_CACHE_DIR:-$PWD/zig-cache}"
						export NIX_CFLAGS_COMPILE=""
					'';
				};
			}
		);
}
