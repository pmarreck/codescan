{
	description = "codescan";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
		profiling.url = "github:pmarreck/performance_profiling/ecf713b81a74a51f76719bf9debc44fe23a0b331";
	};

	outputs = { self, nixpkgs, flake-utils, profiling }:
		flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
			let
				pkgs = import nixpkgs { inherit system; };
				profilingPackage = profiling.packages.${system}.default.overrideAttrs (old: {
					patches = (old.patches or []) ++ [ ./patches/profiler-latency-debounce-fixture.patch ];
				});
				runtimeTools = (with pkgs; [ bash coreutils diffutils findutils git gnugrep gnused gawk gnutar gzip zip unzip jq ripgrep sqlite curl file ]) ++ [ profilingPackage ];
				nativePF = { x86_64-linux = "linux-amd64"; aarch64-linux = "linux-arm64"; aarch64-darwin = "macos-arm64"; }.${system};
				nativeZigTarget = { x86_64-linux = "x86_64-linux-musl"; aarch64-linux = "aarch64-linux-musl"; aarch64-darwin = "aarch64-macos"; }.${system};
				compiledSource = root: pkgs.lib.fileset.toSource {
					inherit root;
					fileset = pkgs.lib.fileset.difference
						(pkgs.lib.fileset.unions [ (root + "/src") (root + "/deps") (root + "/build.zig") (root + "/build.zig.zon") ])
						(pkgs.lib.fileset.unions [
							(pkgs.lib.fileset.maybeMissing (root + "/deps/tree-sitter-c/src"))
							(pkgs.lib.fileset.maybeMissing (root + "/deps/tree-sitter-bash/src"))
							(pkgs.lib.fileset.maybeMissing (root + "/deps/tree-sitter-lua/src"))
							(pkgs.lib.fileset.maybeMissing (root + "/deps/tree-sitter-lean/src"))
							(pkgs.lib.fileset.maybeMissing (root + "/deps/tree-sitter-nim/src"))
							(pkgs.lib.fileset.maybeMissing (root + "/deps/tree-sitter-swift/src"))
						]);
				};
				projectSource = compiledSource ./.;
				cancellationSource = pkgs.lib.fileset.toSource {
					root = ./src;
					fileset = pkgs.lib.fileset.unions [ ./src/embedding_http.zig ./src/io_singleton.zig ];
				};
				mkCancellationTests = pf: target: pkgs.stdenv.mkDerivation {
					pname = "codescan-cancellation-${pf}";
					version = "0.1.0";
					src = cancellationSource;
					nativeBuildInputs = [ pkgs.zig_0_16 ];
					dontConfigure = true;
					dontInstall = true;
					dontFixup = true;
					buildPhase = ''
						cp ${./tests/cancellation-build.zig} build.zig || exit "$?"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
						export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
						zig build -j"$NIX_BUILD_CORES" -Dtarget=${target} -Doptimize=ReleaseSafe --prefix "$out" --color off
					'';
				};
				mkWindowsTestGit = arch:
					let
						asset = {
							amd64 = { suffix = "64-bit"; hash = "sha256-4794NR/nd/ukfd7llQCC+KmLsPAmBP3Huj7iy2j/qHc="; };
							arm64 = { suffix = "arm64"; hash = "sha256-cPdkn3gIjB2x0vNXHKRqBNW+8G5OnVbY7X+YKejGxNs="; };
						}.${arch};
					in pkgs.runCommand "codescan-test-git-mswin-${arch}-2.56.0.4" {
						nativeBuildInputs = [ pkgs.unzip ];
						archive = pkgs.fetchurl {
							url = "https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.4/MinGit-2.56.0.4-${asset.suffix}.zip";
							inherit (asset) hash;
						};
					} ''
						mkdir -p "$out" || exit "$?"
						unzip -q "$archive" -d "$out" || exit "$?"
						test -f "$out/cmd/git.exe" || exit "$?"
					'';
				sqlite-amalgamation = pkgs.fetchzip {
					url = "https://www.sqlite.org/2024/sqlite-amalgamation-3450300.zip";
					sha256 = "sha256-F50oTmmcPIl0AZJbsWAR3tbNAPV3pQLf+CNITzhmXfI=";
					stripRoot = true;
				};

				# Pre-fetch Zig build.zig.zon dependencies for sandboxed builds
				sqlite-vec-src = pkgs.applyPatches {
					name = "sqlite-vec-callback-safe-source";
					src = pkgs.fetchgit {
						url = "https://github.com/pmarreck/sqlite-vec.git";
						rev = "c9d3630f56637276829d9ab0c54b1116c6d3e2ef";
						hash = "sha256-9MBuzlHICNc0U4TIEEPd0gWAftxllXcU8bhilcaAh+k=";
					};
					patches = [ ./patches/sqlite-vec-cleanup-callbacks.patch ];
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
				grammar-c = grammarSource "tree-sitter" "tree-sitter-c"
					"7fa1be1b694b6e763686793d97da01f36a0e5c12"
					"sha256-gmzbdwvrKSo6C1fqTJFGxy8x0+T+vUTswm7F5sojzKc=";
				grammar-lean = grammarSource "Julian" "tree-sitter-lean"
					"efe6b87145608d12f5996bd7f0cf6095a0e82261"
					"sha256-MF+LRzhDw3V/l/h11ZTyWCUCm3b+g0oyOdaCZMVlJc4=";
				grammar-bash = pkgs.runCommand "codescan-bash-source" {
					source = grammarSource "tree-sitter" "tree-sitter-bash"
						"a06c2e4415e9bc0346c6b86d401879ffb44058f7"
						"sha256-ONQ1Ljk3aRWjElSWD2crCFZraZoRj3b3/VELz1789GE=";
				} ''
					cd "$source" || exit "$?"
					sha256sum -c ${./deps/tree-sitter-bash/SOURCE_SHA256} || exit "$?"
					cmp LICENSE ${./deps/tree-sitter-bash/LICENSE} || exit "$?"
					mkdir -p "$out" || exit "$?"
					cp -R src LICENSE "$out/" || exit "$?"
				'';
				grammar-lua = pkgs.runCommand "codescan-lua-source" {
					source = grammarSource "tree-sitter-grammars" "tree-sitter-lua"
						"e40f5b6e6df9c2d1d6d664ff5d346a75d71ee6b2"
						"sha256-tBD2Z+t0YafUeeV7xsFS9Cwe6dR9WewYh2yL/GcIfFw=";
				} ''
					cd "$source" || exit "$?"
					sha256sum -c ${./deps/tree-sitter-lua/SOURCE_SHA256} || exit "$?"
					cmp LICENSE.md ${./deps/tree-sitter-lua/LICENSE.md} || exit "$?"
					mkdir -p "$out" || exit "$?"
					cp -R src LICENSE.md "$out/" || exit "$?"
					'';
				grammar-nim = pkgs.applyPatches {
					name = "codescan-nim-source";
					src = grammarSource "alaviss" "tree-sitter-nim"
						"9b4ede21a6ca866d29263f6b66c070961bc622b4"
						"sha256-3BHcQrLNcXe1RMkV7ECCMzzEukgTlARH3+DDo2M5b0w=";
					patches = [ ./patches/tree-sitter-nim-empty-deserialize.patch ];
				};
				grammar-fish = grammarSource "ram02z" "tree-sitter-fish"
					"f435b0bd772578c70e5d158b85267bb886316f88"
					"sha256-9an4YAz2QKC3yAJ5/tOfmqOJViGATz7+NhKuZpr4oC4=";
				# These native generator assets reproduce the existing ABI-15 source.
				# Updating this tool intentionally requires revalidating SOURCE_SHA256.
				swiftGeneratorAsset = {
					x86_64-linux = { name = "linux-x64"; hash = "sha256-wuDlmnAKniDDBNRndjMjuJuDWh5eNcCOc+31fblzs90="; };
					aarch64-linux = { name = "linux-arm64"; hash = "sha256-N/9IZASXm/HnoTgR0G9EvyuZ3quLc6hncseptIo/u7s="; };
					aarch64-darwin = { name = "macos-arm64"; hash = "sha256-lu2yuue4qxZsFw1qtWroDMAtVqerPxkbct+IMXCb3EY="; };
				}.${system};
				swiftGenerator = pkgs.stdenvNoCC.mkDerivation {
					pname = "codescan-swift-generator";
					version = "0.26.4";
					src = pkgs.fetchurl {
						url = "https://github.com/tree-sitter/tree-sitter/releases/download/v0.26.4/tree-sitter-${swiftGeneratorAsset.name}.gz";
						hash = swiftGeneratorAsset.hash;
					};
					strictDeps = true;
					nativeBuildInputs = [ pkgs.gzip pkgs.file ] ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.autoPatchelfHook;
					buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.glibc pkgs.stdenv.cc.cc.lib ];
					dontUnpack = true;
					dontConfigure = true;
					dontBuild = true;
					dontStrip = true;
					installPhase = ''
						mkdir -p "$out/bin" || exit "$?"
						gzip -dc "$src" > "$out/bin/tree-sitter" || exit "$?"
						chmod +x "$out/bin/tree-sitter" || exit "$?"
					'';
					doInstallCheck = true;
					installCheckPhase = ''
						file --brief "$out/bin/tree-sitter" || exit "$?"
						[ "$("$out/bin/tree-sitter" --version)" = 'tree-sitter 0.26.4' ] || exit 1
					'';
				};
				grammar-swift = pkgs.runCommand "codescan-swift-source-0.7.1" {
					source = pkgs.applyPatches {
						name = "codescan-swift-patched-source";
						src = pkgs.fetchzip {
							url = "https://registry.npmjs.org/tree-sitter-swift/-/tree-sitter-swift-0.7.1.tgz";
							hash = "sha256-pyCOUT30u2t/1lzFPT4In/EHWbNmQS15ZP+LGJahxPE=";
						};
						# Retain these until the selected upstream scanner supplies both
						# unsigned 64-bit shifts; the source oracle must still match.
						patches = [ ./patches/swift-scanner-unsigned-shifts.patch ];
						patchFlags = [ "-p1" "--fuzz=0" ];
					};
					nativeBuildInputs = [ swiftGenerator pkgs.nodejs ];
				} ''
					umask 077
					export HOME="$TMPDIR/home" XDG_CONFIG_HOME="$TMPDIR/config" XDG_CACHE_HOME="$TMPDIR/cache"
					export XDG_DATA_HOME="$TMPDIR/data" XDG_STATE_HOME="$TMPDIR/state" XDG_RUNTIME_DIR="$TMPDIR/runtime"
					export RAYON_NUM_THREADS="$NIX_BUILD_CORES"
					mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" || exit "$?"
					cp -R "$source" work || exit "$?"
					chmod -R u+w work || exit "$?"
					cd work || exit "$?"
					if tree-sitter generate --abi 15 > "$TMPDIR/generation.log" 2>&1; then :; else
						status=$?
						cat "$TMPDIR/generation.log" >&2
						exit "$status"
					fi
					umask 022
					mkdir -p "$out/src/tree_sitter" || exit "$?"
					for path in parser.c scanner.c grammar.json node-types.json tree_sitter/parser.h tree_sitter/alloc.h tree_sitter/array.h; do
						cp "src/$path" "$out/src/$path" || exit "$?"
					done
					cp "$source/LICENSE" "$out/LICENSE" || exit "$?"
					cmp "$out/LICENSE" ${./deps/tree-sitter-swift/LICENSE} || exit "$?"
					cd "$out" || exit "$?"
					sha256sum -c ${./deps/tree-sitter-swift/SOURCE_SHA256} || exit "$?"
				'';
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
				grammar-roc = grammarSource "faldor20" "tree-sitter-roc"
					"2760de95b87004ed537151f2467377a6ddafdef0"
					"sha256-+J7PRYVD4J4mGJIvZnmSKuwGG/vdNkVPuEmCTq8mtwI=";
				grammar-python = grammarSource "tree-sitter" "tree-sitter-python"
					"d326e4cad262cf681656e130960e49dfc04c03ea"
					"sha256-F5XH21PjPpbwYylgKdwD3MZ5o0amDt4xf/e5UikPcxY=";

				# One immutable root keeps build.zig independent of Nix's individual
				# store paths while preserving exact source provenance in this flake.
				grammarSources = pkgs.linkFarm "codescan-tree-sitter-grammars" [
					{ name = "c"; path = "${grammar-c}/src"; }
					{ name = "bash"; path = "${grammar-bash}/src"; }
					{ name = "lua"; path = "${grammar-lua}/src"; }
					{ name = "lean"; path = "${grammar-lean}/src"; }
					{ name = "nim"; path = "${grammar-nim}/src"; }
					{ name = "swift"; path = "${grammar-swift}/src"; }
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
					{ name = "roc"; path = "${grammar-roc}/src"; }
					{ name = "python"; path = "${grammar-python}/src"; }
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
				mkTestBinaries = pname: target: pkgs.stdenv.mkDerivation {
					inherit pname;
					version = "0.1.0";
					src = projectSource;
					nativeBuildInputs = [ pkgs.zig_0_16 ];
					dontConfigure = true;
					dontInstall = true;
					dontFixup = true;
					buildPhase = ''
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR="${sqlite-amalgamation}"
						export CODESCAN_GRAMMAR_ROOT="${grammarSources}"
						export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
						export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
						zig build test-artifacts -j"$NIX_BUILD_CORES" --system ${zigPkgCache} -Dtarget=${target} -Doptimize=ReleaseSafe --prefix "$out" --color off
					'';
				};
				mkCodescan = { target ? nativeZigTarget, pf ? null, profile ? "ReleaseFast", sourceRoot ? ./. }:
				let executable = if target != null && pkgs.lib.hasInfix "-windows-" target then "codescan.exe" else "codescan";
				in pkgs.stdenv.mkDerivation {
					pname = "codescan" + pkgs.lib.optionalString (pf != null) "-${pf}" + pkgs.lib.optionalString (profile != "ReleaseFast") "-${profile}";
					version = "0.1.0";

					src = if sourceRoot == ./. then projectSource else compiledSource sourceRoot;

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
							-j"$NIX_BUILD_CORES" \
							--system ${zigPkgCache} \
							-Doptimize=${profile} \
							${pkgs.lib.optionalString (target != null) "-Dtarget=${target}"} \
							--color off
					'';

					installPhase = ''
						mkdir -p $out/bin
						cp zig-out/bin/${executable} $out/bin/
					'';

					meta = with pkgs.lib; {
						description = "Semantic code search powered by embeddings and tree-sitter";
						license = licenses.mit;
						platforms = platforms.unix;
						mainProgram = executable;
					};
				};
			in {
				packages.default = self.packages.${system}."release-${nativePF}";
				packages.debug = mkCodescan { profile = "Debug"; };
				packages.release-linux-amd64 = mkCodescan { pf = "linux-amd64"; target = "x86_64-linux-musl"; };
				packages.release-linux-arm64 = mkCodescan { pf = "linux-arm64"; target = "aarch64-linux-musl"; };
				packages.release-macos-arm64 = mkCodescan { pf = "macos-arm64"; target = "aarch64-macos"; };
				packages.release-mswin-amd64 = mkCodescan { pf = "mswin-amd64"; target = "x86_64-windows-gnu"; };
				packages.release-mswin-arm64 = mkCodescan { pf = "mswin-arm64"; target = "aarch64-windows-gnu"; };
				packages.cancellation-native = mkCancellationTests nativePF nativeZigTarget;
				packages.cancellation-mswin-amd64 = mkCancellationTests "mswin-amd64" "x86_64-windows-gnu";
				packages.cancellation-mswin-arm64 = mkCancellationTests "mswin-arm64" "aarch64-windows-gnu";
				packages.test-git-mswin-amd64 = mkWindowsTestGit "amd64";
				packages.test-git-mswin-arm64 = mkWindowsTestGit "arm64";

				checks.cancellation-artifacts = pkgs.runCommand "codescan-cancellation-artifacts" {
					nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.file ];
					source = ./tests;
				} ''
					umask 077
					export HOME="$TMPDIR/home" XDG_CONFIG_HOME="$TMPDIR/config" XDG_CACHE_HOME="$TMPDIR/cache"
					export XDG_DATA_HOME="$TMPDIR/data" XDG_STATE_HOME="$TMPDIR/state" XDG_RUNTIME_DIR="$TMPDIR/runtime"
					mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
					bash "$source/unit/test-cancellation-artifacts" \
						${self.packages.${system}.cancellation-native} \
						${self.packages.${system}.cancellation-mswin-amd64} \
						${self.packages.${system}.cancellation-mswin-arm64} || exit "$?"
					bash "$source/unit/test-cancellation-artifact-controls" \
						${self.packages.${system}.cancellation-native} \
						${self.packages.${system}.cancellation-mswin-amd64} \
						${self.packages.${system}.cancellation-mswin-arm64} || exit "$?"
					touch "$out"
				'';

				checks.windows-cancellation-harness = pkgs.runCommand "codescan-windows-cancellation-harness" {
					nativeBuildInputs = [ pkgs.powershell pkgs.git ];
					source = pkgs.lib.fileset.toSource {
						root = ./.;
						fileset = pkgs.lib.fileset.unions [ ./scripts/ci-test-windows.ps1 ./tests/unit/test-windows-cancellation.ps1 ./tests/unit/expected-unit-diagnostics.json ./.github/workflows/native-windows.yml ];
					};
				} ''
					umask 077
					export HOME="$TMPDIR/home" XDG_CONFIG_HOME="$TMPDIR/config" XDG_CACHE_HOME="$TMPDIR/cache"
					export XDG_DATA_HOME="$TMPDIR/data" XDG_STATE_HOME="$TMPDIR/state" XDG_RUNTIME_DIR="$TMPDIR/runtime"
					export DOTNET_CLI_TELEMETRY_OPTOUT=1 POWERSHELL_TELEMETRY_OPTOUT=1
					mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
					pwsh -NoLogo -NoProfile -NonInteractive -File "$source/tests/unit/test-windows-cancellation.ps1" \
						-Amd64Executable ${self.packages.${system}.cancellation-mswin-amd64}/bin/codescan-cancellation-tests.exe \
						-Arm64Executable ${self.packages.${system}.cancellation-mswin-arm64}/bin/codescan-cancellation-tests.exe \
						-NativeUnitExecutable ${self.packages.${system}.test-binaries}/bin/codescan-unit-tests || exit "$?"
					touch "$out"
				'';

				checks.swift-source = grammar-swift;
				checks.bash-source = pkgs.runCommand "codescan-bash-source-identity" {
					source = grammarSources;
				} ''
					cd -P "$source/bash/.." || exit "$?"
					sha256sum -c ${./deps/tree-sitter-bash/SOURCE_SHA256} || exit "$?"
					cmp LICENSE ${./deps/tree-sitter-bash/LICENSE} || exit "$?"
					touch "$out"
				'';
				checks.lua-source = pkgs.runCommand "codescan-lua-source-identity" {
					source = grammarSources;
				} ''
					cd -P "$source/lua/.." || exit "$?"
					sha256sum -c ${./deps/tree-sitter-lua/SOURCE_SHA256} || exit "$?"
					cmp LICENSE.md ${./deps/tree-sitter-lua/LICENSE.md} || exit "$?"
					touch "$out"
					'';
				checks.swift-scanner-shifts = pkgs.runCommand "codescan-swift-scanner-shifts" {
					source = "${grammar-swift}/src";
					nativeBuildInputs = [ pkgs.zig_0_16 ];
				} ''
					export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
					for target in ${nativeZigTarget} x86_64-windows-gnu aarch64-windows-gnu; do
						zig cc -target "$target" -std=c11 -I "$source" -Werror=shift-count-overflow \
							-c "$source/scanner.c" -o "$TMPDIR/$target.o" || exit "$?"
						test -s "$TMPDIR/$target.o" || exit 1
					done
					cp "$source/scanner.c" overflow.c || exit "$?"
					substituteInPlace overflow.c --replace-fail '1ULL << FAKE_TRY_BANG' '1UL << FAKE_TRY_BANG' || exit "$?"
					for target in x86_64-windows-gnu aarch64-windows-gnu; do
						if zig cc -target "$target" -std=c11 -I "$source" -Werror=shift-count-overflow \
							-c overflow.c -o "$TMPDIR/overflow-$target.o" > diagnostic 2>&1; then
							echo "Swift shift control failed to reject $target overflow" >&2
							exit 1
						else
							status=$?
							[ "$status" -eq 1 ] || exit "$status"
						fi
						grep -F 'shift count >= width of type' diagnostic >/dev/null || { cat diagnostic >&2; exit 1; }
					done
					echo "Swift scanner: three ABI compilations and both overflow mutations passed"
					touch "$out"
				'';

				checks.source-closure =
					let
						fixturePackage = mkCodescan { sourceRoot = ./tests/fixtures/source-closure; };
						expected = [ "build.zig" "build.zig.zon" "deps/parser/future.h" "deps/parser/parser.c" "src/docs/data.txt" "src/future/module.zig" "src/main.zig" ];
					in pkgs.runCommand "codescan-source-closure" {
						bashSourceContract = self.checks.${system}.bash-source;
						luaSourceContract = self.checks.${system}.lua-source;
						swiftScannerContract = self.checks.${system}.swift-scanner-shifts;
						fixtureSource = fixturePackage.src;
						unfilteredFixture = ./tests/fixtures/source-closure;
						expectedFiles = pkgs.writeText "codescan-expected-source-files" (pkgs.lib.concatStringsSep "\n" expected + "\n");
						nativeBuildInputs = [ pkgs.findutils pkgs.coreutils pkgs.diffutils ];
					} ''
						find "$fixtureSource" -type f -printf '%P\n' > paths || exit "$?"
						LC_ALL=C sort paths > actual || exit "$?"
						diff -u "$expectedFiles" actual || exit "$?"
						find "$unfilteredFixture" -type f -printf '%P\n' > control-paths || exit "$?"
						LC_ALL=C sort control-paths > control || exit "$?"
						if cmp -s "$expectedFiles" control; then
							echo "source-closure negative control must contain excluded inputs" >&2
							exit 1
						else
							control_status=$?
							[ "$control_status" -eq 1 ] || exit "$control_status"
						fi
						touch "$out"
					'';

				packages.test-binaries = mkTestBinaries "codescan-test-binaries" nativeZigTarget;
				packages.test-binaries-mswin-amd64 = mkTestBinaries "codescan-test-binaries-mswin-amd64" "x86_64-windows-gnu";
				packages.test-binaries-mswin-arm64 = mkTestBinaries "codescan-test-binaries-mswin-arm64" "aarch64-windows-gnu";

				checks.compiler-concurrency = pkgs.runCommand "codescan-compiler-concurrency" {
					cliPhase = self.packages.${system}.default.buildPhase;
					unitPhase = self.packages.${system}.test-binaries.buildPhase;
					windowsAmd64UnitPhase = self.packages.${system}.test-binaries-mswin-amd64.buildPhase;
					windowsArm64UnitPhase = self.packages.${system}.test-binaries-mswin-arm64.buildPhase;
					cancellationPhase = self.packages.${system}.cancellation-native.buildPhase;
					passAsFile = [ "cliPhase" "unitPhase" "windowsAmd64UnitPhase" "windowsArm64UnitPhase" "cancellationPhase" ];
					nativeBuildInputs = [ pkgs.bash pkgs.coreutils ];
				} ''
					set +e
					set -u
					zig() {
						[ "$1" = build ] || return 64
						printf 'call\n' >> "$PROBE_CALLS"
						local argument
						for argument in "$@"; do
							case "$argument" in -j*) printf '%s\n' "$argument" >> "$PROBE_JOBS" ;; esac
						done
					}
					export -f zig
					failed=0
					for phase in "$cliPhasePath" "$unitPhasePath" "$windowsAmd64UnitPhasePath" "$windowsArm64UnitPhasePath" "$cancellationPhasePath"; do
						for cores in 1 4 12; do
							export PROBE_CALLS="$TMPDIR/calls" PROBE_JOBS="$TMPDIR/jobs"
							: > "$PROBE_CALLS"
							: > "$PROBE_JOBS"
							probe="$TMPDIR/$(basename "$phase")-$cores"
							mkdir "$probe" || exit "$?"
							if (cd "$probe" && env NIX_BUILD_CORES="$cores" out="$probe/product" bash "$phase"); then :; else failed=1; fi
							if [ "$(< "$PROBE_CALLS")" != call ] || [ "$(< "$PROBE_JOBS")" != "-j$cores" ]; then
								printf 'compiler phase did not request exactly one -j%s build\n' "$cores" >&2
								failed=1
							fi
						done
					done
					[ "$failed" -eq 0 ] || exit 1
					touch "$out"
				'';

				# Reuse the complete prepared runtime suite inside the Nix sandbox.
				# Compilation stays in separate reusable artifact derivations.
				checks.test = pkgs.stdenv.mkDerivation {
					pname = "codescan-test";
					version = "0.1.0";
					bashSourceContract = self.checks.${system}.bash-source;
					compilerConcurrencyContract = self.checks.${system}.compiler-concurrency;
					luaSourceContract = self.checks.${system}.lua-source;
					cancellationArtifactContract = self.checks.${system}.cancellation-artifacts;
					windowsHarnessContract = self.checks.${system}.windows-cancellation-harness;
					swiftScannerContract = self.checks.${system}.swift-scanner-shifts;
					src = ./.;
					nativeBuildInputs = runtimeTools;
					dontConfigure = true;
					dontFixup = true;
					buildPhase = ''
						export HOME="$TMPDIR/home"
						export XDG_CONFIG_HOME="$TMPDIR/config" XDG_DATA_HOME="$TMPDIR/data"
						export XDG_STATE_HOME="$TMPDIR/state" XDG_CACHE_HOME="$TMPDIR/cache"
						export XDG_RUNTIME_DIR="$TMPDIR/runtime" TEST_WORKSPACE="$TMPDIR/workspace"
						mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$TEST_WORKSPACE"
						patchShebangs build run reindex_all scripts/ci-build scripts/ci-verify-macos-arm64 tests
						git init -q
						git add .
						export CODESCAN_TEST_BIN=${self.packages.${system}.default}/bin/codescan
						export CODESCAN_TEST_DB_BIN=${self.packages.${system}.test-binaries}/bin/mk-test-db
						export CODESCAN_UNIT_TEST_BIN=${self.packages.${system}.test-binaries}/bin/codescan-unit-tests
						export CODESCAN_EXPECT_PF=${nativePF} CODESCAN_EXPECT_VARIANT="${if pkgs.stdenv.isLinux then "musl" else ""}"
						export OLLAMA_URL=http://127.0.0.1:1
						bash ./tests/run-prepared
					'';
					installPhase = ''
						mkdir -p $out
						echo "available runtime suites passed; live-provider exclusions are recorded in the build log" > $out/result
					'';
				};

				devShells.default = pkgs.mkShell {
					packages = with pkgs; [
						zig_0_16
						git
						bash
						coreutils
						diffutils
						gnutar
						zip
						unzip
						ripgrep
						curl
						jq
						file
						sqlite
						luajit
						luajitPackages.cjson
					] ++ [ profilingPackage ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.bubblewrap ];
					shellHook = "
						export CODESCAN_TEST_PATH=\"${pkgs.lib.makeBinPath runtimeTools}\"
						export SQLITE_VEC_SQLITE_AMALGAMATION_DIR=\"${sqlite-amalgamation}\"
						export CODESCAN_GRAMMAR_ROOT=\"${grammarSources}\"
						export ZIG_GLOBAL_CACHE_DIR=\"\${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}\"
						export ZIG_LOCAL_CACHE_DIR=\"\${ZIG_LOCAL_CACHE_DIR:-$PWD/zig-cache}\"
						export NIX_CFLAGS_COMPILE=\"\"
					";
				};
			}
		);
}
