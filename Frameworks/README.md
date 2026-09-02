# whisper.xcframework — build recipe

`whisper.xcframework` is a real, working macOS arm64-only build of
[`ggml-org/whisper.cpp`](https://github.com/ggml-org/whisper.cpp)
(specifically built at commit `eacbd8234c6654cdbf2c377f72b2106875479bdc`,
2026-08-31), used by `Sources/Clio/Services/WhisperCppEngine.swift` for
on-device transcription.

**Not committed to git** (see `.gitignore`) — deterministically
reproducible from public upstream source via the steps below, the same
"large binary build artifact" reasoning as the ML models in
`docs/MODEL_SETUP.md`.

## Why a manual build instead of the official `build-xcframework.sh`

whisper.cpp's own script builds iOS + macOS + visionOS + tvOS together
(slow, and drags in mobile-platform toolchains not needed here). Clio
also restricts itself to `arm64` only (see
`EXCLUDED_ARCHS[sdk=macosx*] = x86_64` in `Clio.xcodeproj`), so this
recipe replicates just the macOS-only portion of that script directly.

## 1. Clone and build the static libraries

```bash
git clone https://github.com/ggml-org/whisper.cpp.git /tmp/whisper.cpp
cd /tmp/whisper.cpp
git checkout eacbd8234c6654cdbf2c377f72b2106875479bdc

brew install cmake   # if not already installed

cmake -B build-macos -G Xcode \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF

# Debug config lacks debug symbols in this project's generated Xcode
# project — use RelWithDebInfo so dsymutil has something real to extract
# (see step 3; a Release-config build silently produces a dSYM-less
# binary, which is what caused a real "Upload Symbols Failed" warning on
# App Store Connect — see CHANGELOG.md).
cmake --build build-macos --config RelWithDebInfo --target whisper -j$(sysctl -n hw.ncpu)
```

This produces (paths relative to `build-macos/`):
- `ggml/src/RelWithDebInfo/libggml.a`, `libggml-base.a`, `libggml-cpu.a`
- `ggml/src/ggml-metal/RelWithDebInfo/libggml-metal.a`
- `ggml/src/ggml-blas/RelWithDebInfo/libggml-blas.a`
- `src/RelWithDebInfo/libwhisper.a`

## 2. Link a single dylib from the static libs

```bash
mkdir -p /tmp/whisper_build
cd /tmp/whisper.cpp/build-macos
clang++ -dynamiclib \
  -arch arm64 \
  -mmacosx-version-min=14.0 \
  -install_name @rpath/whisper.framework/Versions/Current/whisper \
  -o /tmp/whisper_build/whisper \
  -Wl,-force_load,src/RelWithDebInfo/libwhisper.a \
  -Wl,-force_load,ggml/src/RelWithDebInfo/libggml.a \
  -Wl,-force_load,ggml/src/RelWithDebInfo/libggml-base.a \
  -Wl,-force_load,ggml/src/RelWithDebInfo/libggml-cpu.a \
  -Wl,-force_load,ggml/src/ggml-metal/RelWithDebInfo/libggml-metal.a \
  -Wl,-force_load,ggml/src/ggml-blas/RelWithDebInfo/libggml-blas.a \
  -framework Foundation -framework Metal -framework Accelerate -framework CoreFoundation \
  -lc++ -lobjc
```

## 3. Generate a real dSYM

```bash
dsymutil /tmp/whisper_build/whisper -o /tmp/whisper_build/whisper.dSYM
```

Confirm it actually contains DWARF (not just a symbol table) before
proceeding — `dwarfdump --debug-info /tmp/whisper_build/whisper.dSYM/Contents/Resources/DWARF/whisper | grep -c DW_TAG_compile_unit`
should print a real number (dozens), not `0`. If it's `0`, the static
libs were built with `Release` instead of `RelWithDebInfo` in step 1.

## 4. Assemble the framework bundle

```bash
mkdir -p /tmp/whisper_build/whisper.framework/Versions/A/{Headers,Modules,Resources}
cp /tmp/whisper_build/whisper /tmp/whisper_build/whisper.framework/Versions/A/
cp /tmp/whisper.cpp/include/whisper.h \
   /tmp/whisper.cpp/include/parakeet.h \
   /tmp/whisper.cpp/ggml/include/*.h \
   /tmp/whisper_build/whisper.framework/Versions/A/Headers/
# module.modulemap (Modules/) and Info.plist (Resources/) — see the
# existing Frameworks/whisper.xcframework/macos-arm64/whisper.framework
# tree for the exact expected content/structure if rebuilding from
# scratch and this framework is not available as a reference.

ln -s A /tmp/whisper_build/whisper.framework/Versions/Current
ln -s Versions/Current/Headers /tmp/whisper_build/whisper.framework/Headers
ln -s Versions/Current/Modules /tmp/whisper_build/whisper.framework/Modules
ln -s Versions/Current/Resources /tmp/whisper_build/whisper.framework/Resources
ln -s Versions/Current/whisper /tmp/whisper_build/whisper.framework/whisper

codesign --force --sign - /tmp/whisper_build/whisper.framework/Versions/A/whisper
```

(Xcode's own Archive/Embed Frameworks step re-signs this with the app's
real signing identity at build time — the ad-hoc signature here is only
so the framework is loadable for local development/testing of the
xcframework build itself.)

## 5. Create the xcframework with the dSYM attached

```bash
xcodebuild -create-xcframework \
  -framework /tmp/whisper_build/whisper.framework \
  -debug-symbols /tmp/whisper_build/whisper.dSYM \
  -output /tmp/whisper_build/whisper.xcframework

rm -rf Frameworks/whisper.xcframework
cp -R /tmp/whisper_build/whisper.xcframework Frameworks/whisper.xcframework
```

## Verifying the result

```bash
# Real beam-search symbols present (confirms this isn't a stub build):
nm Frameworks/whisper.xcframework/macos-arm64/whisper.framework/whisper | grep -i beam_search

# dSYM UUID matches the framework binary (required for App Store Connect
# symbol upload to succeed without warning):
dwarfdump --uuid Frameworks/whisper.xcframework/macos-arm64/dSYMs/whisper.dSYM
dwarfdump --uuid Frameworks/whisper.xcframework/macos-arm64/whisper.framework/whisper
```
