#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_REPO="${1:-$ROOT_DIR/../iOS-eSIM}"
ANDROID_REPO="${2:-$ROOT_DIR/../android-esim}"
OUT_FILE="$ROOT_DIR/data/esim-sdk-snapshot.json"

if [[ ! -d "$IOS_REPO/.git" ]]; then
  echo "iOS repo not found at $IOS_REPO" >&2
  exit 1
fi
if [[ ! -d "$ANDROID_REPO/.git" ]]; then
  echo "Android repo not found at $ANDROID_REPO" >&2
  exit 1
fi

trim() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"
}

json_array_from_lines() {
  jq -R -s 'split("\n") | map(select(length > 0))'
}

# iOS
IOS_BRANCH="$(git -C "$IOS_REPO" rev-parse --abbrev-ref HEAD)"
IOS_COMMIT="$(git -C "$IOS_REPO" rev-parse --short HEAD)"
IOS_DATE="$(git -C "$IOS_REPO" log -1 --format=%cs)"
IOS_MIN="$(rg '\.iOS\(\.v[0-9]+' "$IOS_REPO/Package.swift" -o | head -n1 | sed -E 's/.*\.v([0-9]+)/iOS \1+/')"
IOS_SWIFT="$(rg 'swift-tools-version' "$IOS_REPO/Package.swift" | head -n1 | sed -E 's#.*: *##')"
IOS_XCODE="$(rg 'Xcode [0-9]+\.[0-9]+' "$IOS_REPO/README.md" -o | head -n1 | tr -d '\r')"
IOS_PKG_DEPS="$( (rg -n '\.package\(' "$IOS_REPO/Package.swift" || true) | sed -E 's/^[0-9]+://' | sed -E 's/[[:space:]]+/ /g' | tr -d '\r' | json_array_from_lines)"
IOS_PUBLIC_API="$( (rg -n '^\s*public static func ' "$IOS_REPO/PagoESIMSDK/PagoESIMManager.swift" || true) | sed -E 's/^[0-9]+://' | sed -E 's/[[:space:]]+/ /g' | json_array_from_lines)"
IOS_NOTIFS="$( (rg -n '\.(paymentEntitySelected|externalPaymentCompleted|externalPaymentFailed)\b' "$IOS_REPO/PagoESIMSDK" || true) | head -n 12 | sed -E 's#^.*/PagoESIMSDK/##' | json_array_from_lines)"

# Android
ANDROID_BRANCH="$(git -C "$ANDROID_REPO" rev-parse --abbrev-ref HEAD)"
ANDROID_COMMIT="$(git -C "$ANDROID_REPO" rev-parse --short HEAD)"
ANDROID_DATE="$(git -C "$ANDROID_REPO" log -1 --format=%cs)"
COMPILE_SDK="$(rg 'compileSdk\s+[0-9]+' "$ANDROID_REPO/app/esim/build.gradle" -o | head -n1 | awk '{print $2}')"
MIN_SDK="$(rg 'minSdk\s+[0-9]+' "$ANDROID_REPO/app/esim/build.gradle" -o | head -n1 | awk '{print $2}')"
TARGET_SDK="$(rg 'targetSdk\s+[0-9]+' "$ANDROID_REPO/app/esim/build.gradle" -o | head -n1 | awk '{print $2}')"
JAVA_VERSION="$(rg 'JavaLanguageVersion\.of\([0-9]+\)' "$ANDROID_REPO/app/esim/build.gradle" -o | head -n1 | sed -E 's/.*\(([0-9]+)\).*/\1/')"
ANDROID_DEPS="$( (rg -n '^(\s*)(api|implementation|compileOnly)\s+libs\.' "$ANDROID_REPO/app/esim/build.gradle" || true) | sed -E 's/^[0-9]+://' | sed -E 's/[[:space:]]+/ /g' | head -n 25 | json_array_from_lines)"
ANDROID_PERMS="$( (rg -n '<uses-permission[^>]+>' "$ANDROID_REPO/app/esim/src/main/AndroidManifest.xml" || true) | sed -E 's/^[0-9]+://' | sed -E 's/[[:space:]]+/ /g' | json_array_from_lines)"
ANDROID_FEATURES="$( (rg -n '<uses-feature[^>]+>' "$ANDROID_REPO/app/esim/src/main/AndroidManifest.xml" || true) | sed -E 's/^[0-9]+://' | sed -E 's/[[:space:]]+/ /g' | json_array_from_lines)"
ANDROID_PUBLIC_API="$( (rg -n '^\s*(override\s+)?fun\s+(loadConfig|startFlow|finishFlow|addFlowFinishListener|addPagoPaymentEntitySelector|setFonts|addPagoInterceptors)\b' "$ANDROID_REPO/app/esim/src/main/kotlin/app/pago/esim/PagoEsimConfigurator.kt" "$ANDROID_REPO/app/esim/src/main/kotlin/app/pago/esim/PagoEsimManager.kt" || true) | sed -E 's#^.*/app/esim/src/main/kotlin/app/pago/esim/##' | sed -E 's/^[0-9]+://' | sed -E 's/[[:space:]]+/ /g' | json_array_from_lines)"
ANDROID_DOCS="$(find "$ANDROID_REPO/docs" -type f | sed -E 's#^.*/docs/##' | sort | json_array_from_lines)"

jq -n \
  --arg generatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg iosRepo "PagoApp/iOS-eSIM" \
  --arg iosBranch "$IOS_BRANCH" \
  --arg iosCommit "$IOS_COMMIT" \
  --arg iosDate "$IOS_DATE" \
  --arg iosMin "$IOS_MIN" \
  --arg iosSwift "$IOS_SWIFT" \
  --arg iosXcode "$IOS_XCODE" \
  --arg androidRepo "PagoApp/android-esim" \
  --arg androidBranch "$ANDROID_BRANCH" \
  --arg androidCommit "$ANDROID_COMMIT" \
  --arg androidDate "$ANDROID_DATE" \
  --arg compileSdk "$COMPILE_SDK" \
  --arg minSdk "$MIN_SDK" \
  --arg targetSdk "$TARGET_SDK" \
  --arg javaVersion "$JAVA_VERSION" \
  --argjson iosPkgDeps "$IOS_PKG_DEPS" \
  --argjson iosPublicApi "$IOS_PUBLIC_API" \
  --argjson iosNotifs "$IOS_NOTIFS" \
  --argjson androidDeps "$ANDROID_DEPS" \
  --argjson androidPerms "$ANDROID_PERMS" \
  --argjson androidFeatures "$ANDROID_FEATURES" \
  --argjson androidPublicApi "$ANDROID_PUBLIC_API" \
  --argjson androidDocs "$ANDROID_DOCS" \
  '{
    generatedAt: $generatedAt,
    sourceRepos: {
      ios: {
        repository: $iosRepo,
        branch: $iosBranch,
        commit: $iosCommit,
        lastCommitDate: $iosDate
      },
      android: {
        repository: $androidRepo,
        branch: $androidBranch,
        commit: $androidCommit,
        lastCommitDate: $androidDate
      }
    },
    ios: {
      requirements: {
        minOS: $iosMin,
        swiftTools: $iosSwift,
        xcode: $iosXcode
      },
      packageDependencies: $iosPkgDeps,
      publicEntryPoints: $iosPublicApi,
      notificationSignals: $iosNotifs
    },
    android: {
      requirements: {
        compileSdk: $compileSdk,
        minSdk: $minSdk,
        targetSdk: $targetSdk,
        java: $javaVersion
      },
      gradleDependenciesSample: $androidDeps,
      manifestPermissions: $androidPerms,
      manifestFeatures: $androidFeatures,
      publicEntryPoints: $androidPublicApi,
      docsCatalog: $androidDocs
    }
  }' > "$OUT_FILE"

echo "Generated $OUT_FILE"
