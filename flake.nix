{
  description = "Wallpaper Engine";

  inputs = {
    self.submodules = true;

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust-overlay) ];

        pkgs = import nixpkgs {
          inherit system overlays;
        };

        lib = pkgs.lib;

        nixLib = import ./nix/lib.nix { inherit pkgs; };

        apple-libs = nixLib.env;

        buildScripts = nixLib.build;

        rustToolchain = pkgs.pkgsBuildHost.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

        xcodeConfiguration = "Release";

        nativeBuildTools = with pkgs; [
          rustToolchain
          cmake
          ninja
          pkg-config
          python3
          jq
        ];

        engineLibraries = with pkgs; [
          libiconv
          eigen
          nlohmann_json
          glslang.dev
          glslang.out
          spirv-tools.dev
          spirv-tools
          argparse
          quickjs-ng.dev
          quickjs-ng
          glm
          lz4.dev
          lz4
          freetype.dev
          freetype
          ffmpeg.dev
          ffmpeg
          shaderc
          vulkan-headers
          vulkan-loader
          moltenvk
          vulkan-tools
          vulkan-validation-layers

          apple-sdk_26
        ];

        # The CI cache package builds inside a fixed directory. Compiler caches
        # (ccache/sccache) hash the preprocessed translation unit, which embeds
        # absolute paths; a per-run `$TMPDIR/nix-build-*` directory would make
        # every cache lookup miss. A stable root keeps paths identical between
        # runs so the caches actually pay off.
        cacheRoot = "/private/tmp/wallpaper-engine-ci";

        # Both wrappers fall back to the real compiler if caching fails, so a
        # broken cache can slow the build down but never break it.
        rustcWrapper = pkgs.writeShellScriptBin "rustc-sccache" ''
          if ${pkgs.sccache}/bin/sccache "$@"; then
            exit 0
          fi
          echo "warning: sccache failed; falling back to plain rustc" >&2
          exec "$@"
        '';

        cmakeLauncher = pkgs.writeShellScriptBin "ccache-launcher" ''
          if ${pkgs.ccache}/bin/ccache "$@"; then
            exit 0
          fi
          echo "warning: ccache failed; falling back to the plain compiler" >&2
          exec "$@"
        '';

        mkPackage =
          {
            extraEnv ? { },
            extraTools ? [ ],
          }:
          pkgs.stdenv.mkDerivation (
            {
              pname = "wallpaper-engine";

              version = "0.2.0";

              src = ./.;

              nativeBuildInputs = nativeBuildTools ++ [ pkgs.rustPlatform.cargoSetupHook ] ++ extraTools;
              buildInputs = engineLibraries;

              dontConfigure = true;
              dontFixup = true;

              cargoDeps = pkgs.rustPlatform.importCargoLock { lockFile = ./Cargo.lock; };

              buildPhase = ''
                runHook preBuild

                mark() { printf '\n=== %s  %s ===\n' "$(date -u '+%H:%M:%S')" "$*"; }

                CARGO_ARGS=()

                if [ -n "''${WALLPAPER_CI_CACHE_ROOT:-}" ]; then
                  mark "relocate build tree into ''$WALLPAPER_CI_CACHE_ROOT/work (stable paths for compiler caches)"
                  mkdir -p "''$WALLPAPER_CI_CACHE_ROOT"
                  mkdir -p "''$CCACHE_DIR" "''$SCCACHE_DIR"
                  rm -rf "''$WALLPAPER_CI_CACHE_ROOT/work"
                  mkdir -p "''$WALLPAPER_CI_CACHE_ROOT/work"
                  cp -a . "''$WALLPAPER_CI_CACHE_ROOT/work"/
                  SRC_ROOT="$PWD"
                  cd "''$WALLPAPER_CI_CACHE_ROOT/work"

                  # cargoSetupPostUnpackHook writes `.cargo/config.toml` in the
                  # build root (the *parent* of the unpacked source tree) and
                  # points it at an absolute vendored-sources directory. Cargo
                  # finds it by walking up from the source root, so relocating
                  # the tree silently drops the vendored source replacement and
                  # sends cargo to crates.io — which fails, because the build has
                  # no CA trust store. Bring the config along and re-assert the
                  # vendored source through the CLI (highest precedence).
                  if [ -f "$SRC_ROOT/../.cargo/config.toml" ]; then
                    mkdir -p .cargo
                    cp "$SRC_ROOT/../.cargo/config.toml" .cargo/config.toml
                  fi

                  VENDOR_DIR="''${cargoDepsCopy:-$(dirname "$SRC_ROOT")/cargo-vendor-dir}"
                  echo "--- cargo vendoring ---"
                  cat .cargo/config.toml 2>&1 || true
                  echo "vendor directory: $VENDOR_DIR"

                  echo "--- vendored libgit2-sys layout ---"
                  for crate in "$VENDOR_DIR"/libgit2-sys-*; do
                    echo "crate: $crate"
                    ls -la "$crate" 2>&1 | head -12
                    ls -la "$crate/libgit2" 2>&1 | head -8
                    ls -la "$crate/libgit2/include" 2>&1 | head -8
                  done

                  if [ -d "$VENDOR_DIR" ]; then
                    cat > "''$WALLPAPER_CI_CACHE_ROOT/cargo-vendor.toml" <<EOF
                [source."crates-io"]
                replace-with = "vendored-sources"

                [source."vendored-sources"]
                directory = "$VENDOR_DIR"
                EOF
                    CARGO_ARGS=(--config "''$WALLPAPER_CI_CACHE_ROOT/cargo-vendor.toml" --offline)
                  else
                    echo "error: vendored crates directory not found at $VENDOR_DIR" >&2
                    exit 1
                  fi
                fi

                export GIT_SHORT_COMMIT=${self.shortRev or self.dirtyShortRev}
                ${apple-libs.fakeHomeSetupScript}

                export CARGO_TARGET_DIR="''${CARGO_TARGET_DIR:-$PWD/target}"

                mark "cargo build (rust workspace)"
                cargo build "''${CARGO_ARGS[@]}" --workspace --release

                mark "cargo build (uniffi-bindgen)"
                cargo build \
                    "''${CARGO_ARGS[@]}" \
                    --release \
                    -p wallpaper-bridge \
                    --bin uniffi-bindgen

                mark "xcode preflight"
                ${apple-libs.xcodePreflightScript}
                ${apple-libs.resolveDeveloperDirScript}

                export SDKROOT=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)

                mkdir -p \
                    app/WallpaperEngine/Bridge/Generated

                mark "uniffi bindgen"
                "$CARGO_TARGET_DIR/release/uniffi-bindgen" \
                    generate \
                    --library "$CARGO_TARGET_DIR/release/libwallpaper_bridge.a" \
                    --language swift \
                    --no-format \
                    --out-dir app/WallpaperEngine/Bridge/Generated

                export BUILD_DIR="$TMPDIR/build"
                mkdir -p "$BUILD_DIR"

                mark "xcodebuild (swift app)"
                /usr/bin/xcodebuild \
                    -project app/WallpaperEngine.xcodeproj \
                    -scheme WallpaperEngine \
                    -configuration ${xcodeConfiguration} \
                    -derivedDataPath "$BUILD_DIR" \
                    OBJROOT="$BUILD_DIR/Intermediates" \
                    SYMROOT="$BUILD_DIR/Products" \
                    CONFIGURATION_BUILD_DIR="$BUILD_DIR/${xcodeConfiguration}" \
                    OTHER_SWIFT_FLAGS='$(inherited) -Xcc -fmodule-map-file=$(SRCROOT)/WallpaperEngine/Bridge/Generated/WallpaperBridgeFFI.modulemap -disable-sandbox' \
                    build

                APP="$BUILD_DIR/${xcodeConfiguration}/Wallpaper Engine.app"

                mark "package app bundle"
                ${buildScripts.packageBundleScript}

                mark "compiler cache stats"
                if command -v sccache >/dev/null 2>&1; then
                  sccache --show-stats || true
                fi
                if command -v ccache >/dev/null 2>&1; then
                  ccache --show-stats || true
                fi

                runHook postBuild
              '';

              installPhase = ''
                runHook preInstall

                mkdir -p "$out/Applications"

                cp -R \
                  "$BUILD_DIR/${xcodeConfiguration}/Wallpaper Engine.app" \
                  "$out/Applications/"

                runHook postInstall
              '';

              doInstallCheck = true;

              installCheckPhase = ''
                runHook preInstallCheck

                APP="$out/Applications/Wallpaper Engine.app"
                ${buildScripts.validateBundleScript}

                runHook postInstallCheck
              '';
            }
            // extraEnv
          );
      in
      lib.optionalAttrs pkgs.stdenv.isDarwin {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = nativeBuildTools;
          buildInputs = engineLibraries;
        };

        packages.default = mkPackage { };

        # Same derivation plus compiler caches. Used by CI only; the directories
        # under `cacheRoot` are persisted between workflow runs.
        packages.ci = mkPackage {
          extraTools = [
            pkgs.ccache
            pkgs.sccache
          ];

          extraEnv = {
            WALLPAPER_CI_CACHE_ROOT = cacheRoot;

            # ccache: C++/ObjC++ from the vendored Vulkan renderer.
            CCACHE_DIR = "${cacheRoot}/ccache";
            CCACHE_BASEDIR = cacheRoot;
            CCACHE_NOHASHDIR = "1";
            CCACHE_COMPRESS = "1";
            CCACHE_MAXSIZE = "1G";
            CCACHE_UMASK = "000";

            # sccache: every rustc invocation, including the 300+ crates from
            # Cargo.lock.
            SCCACHE_DIR = "${cacheRoot}/sccache";
            SCCACHE_CACHE_SIZE = "3G";
            SCCACHE_ERROR_LOG = "${cacheRoot}/sccache.log";
            RUSTC_WRAPPER = "${rustcWrapper}/bin/rustc-sccache";

            OWE_CMAKE_COMPILER_LAUNCHER = "${cmakeLauncher}/bin/ccache-launcher";

            CARGO_INCREMENTAL = "0";
          };
        };
      }
    );
}
