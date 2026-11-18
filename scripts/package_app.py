"""Bundle and ad-hoc sign local Swift products. No installation, network or global configuration."""
import argparse
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", nargs="?", default="debug", choices=["debug", "release"])
parser.add_argument("--output", type=pathlib.Path)
parser.add_argument("--channel", choices=["daily", "review"], default="daily")
options = parser.parse_args()
mode = options.mode
version_file = root / "VERSION"
version = version_file.read_text().strip() if version_file.exists() else None
if version is not None and re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)\.[1-9][0-9]*)?", version) is None:
    raise SystemExit("VERSION must contain the owner-selected release version")
build_number = (root / "BUILD_NUMBER").read_text().strip() if version is not None else None
if build_number is not None and re.fullmatch(r"[1-9][0-9]*(?:\.[0-9]+){0,2}", build_number) is None:
    raise SystemExit("BUILD_NUMBER must be an explicit positive numeric bundle build")
app = (options.output or root / "build" / "artifacts.noindex" / "Cueport.app").absolute()
bundle_id = "org.agentattentionrouter.review" if options.channel == "review" else "org.agentattentionrouter.local-development"
if options.channel == "review" and options.output is None:
    raise SystemExit("Review builds require an explicit --output; the daily bundle is preserved")
macos = app / "Contents" / "MacOS"
resources = app / "Contents" / "Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "THIRD_PARTY_NOTICES.md", resources / "ThirdPartyNotices.md")
subprocess.run(["swift", str(root / "scripts/render_icon.swift"), str(root / "build/AppIcon.iconset")], check=True)
subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(root / "build/AppIcon.iconset"), "-o", str(resources / "AppIcon.icns")], check=True)
with tempfile.TemporaryDirectory(prefix="status-assets-", dir=root / "build") as temporary:
    catalog = pathlib.Path(temporary) / "Status.xcassets"
    image_set = catalog / "AARStatusIndicator.imageset"
    image_set.mkdir(parents=True)
    subprocess.run(["swift", str(root / "scripts/render_status_asset.swift"), str(image_set)], check=True)
    subprocess.run(["/usr/bin/xcrun", "actool", str(catalog), "--compile", str(resources),
                    "--platform", "macosx", "--minimum-deployment-target", "14.0",
                    "--target-device", "mac", "--output-partial-info-plist",
                    str(pathlib.Path(temporary) / "asset-info.plist")], check=True, capture_output=True)
    if not (resources / "Assets.car").is_file():
        raise SystemExit("Status template asset catalog was not produced")
for name in ["CueportApp", "cueport", "aar"]:
    # A bridge worker may still have the previous executable mapped. Never
    # overwrite that inode: macOS can kill it when signed code pages change.
    staging = macos / ("." + name + "-" + uuid.uuid4().hex)
    # Keep receiver and helper names distinct on case-insensitive filesystems.
    # The cueport CLI is an alias of the aar build for existing integrations.
    product = "aar" if name == "cueport" else name
    shutil.copy2(root / "build" / "swift" / mode / product, staging)
    if mode == "release":
        # Omit debug-map/source paths and local linker symbols from distribution.
        # Keep global symbols and runtime metadata; retain local dSYMs separately.
        subprocess.run(["/usr/bin/strip", "-S", "-x", str(staging)], check=True, capture_output=True)
    if name in {"cueport", "aar"}:
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", bundle_id + ".helper", str(staging)], check=True, capture_output=True)
    staging.replace(macos / name)
info = {
    "CFBundleExecutable": "CueportApp",
    "CFBundleIdentifier": bundle_id,
    "CFBundleName": "Cueport",
    "CFBundleDisplayName": "Cueport TEST" if options.channel == "review" else "Cueport",
    "CFBundlePackageType": "APPL",
    "LSApplicationCategoryType": "public.app-category.developer-tools",
    "CFBundleIconFile": "AppIcon",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "LSMinimumSystemVersion": "14.0",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": "Cueport contributors",
    "AARBuildChannel": options.channel,
}
if version is not None:
    # macOS requires numeric bundle versions; retain the full prerelease label
    # separately instead of putting an invalid SemVer suffix in a numeric key.
    info.update(CFBundleShortVersionString=version.split("-")[0],
                CFBundleVersion=build_number,
                AARReleaseVersion=version)
(app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
if (macos / "CueportApp").samefile(macos / "cueport"):
    raise SystemExit("Receiver and CLI must be distinct files")
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", info["CFBundleIdentifier"], str(app)], check=True)
asset_check = root / "build/check-status-asset"
subprocess.run(["swiftc", "-parse-as-library", str(root / "scripts/check_status_asset.swift"),
                "-o", str(asset_check)], check=True)
subprocess.run([str(asset_check), str(app)], check=True)
print(f"Local development bundle: {app}")
print("Signing: local ad-hoc only (no Developer ID). Notarization: not performed. No installation or Hook changes.")
