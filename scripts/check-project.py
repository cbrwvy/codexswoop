#!/usr/bin/env python3
"""Read-only release structure/resource checks. Does not run any application."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise SystemExit("FAIL project: " + message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path)
    args = parser.parse_args()
    project = json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(ROOT / "CodexSwoop.xcodeproj/project.pbxproj")
    ]))
    objects = project["objects"]
    targets = {o["name"]: o for o in objects.values() if o.get("isa") == "PBXNativeTarget"}
    require(set(targets) == {"CodexSwoop", "CodexSwoopCoreTests"}, "app and hostless XCTest targets")
    app, tests = targets["CodexSwoop"], targets["CodexSwoopCoreTests"]
    require(tests["productType"] == "com.apple.product-type.bundle.unit-test", "native XCTest product")

    def configurations(target):
        return {objects[i]["name"]: objects[i]["buildSettings"] for i in objects[target["buildConfigurationList"]]["buildConfigurations"]}

    def paths(target, phase_type):
        result = set()
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] == phase_type:
                for build_id in phase["files"]:
                    result.add(objects[objects[build_id]["fileRef"]]["path"])
        return result

    require(paths(app, "PBXSourcesBuildPhase") == {str(p.relative_to(ROOT)) for p in (ROOT / "Sources/CodexSwoop").glob("*.swift")}, "all app sources registered")
    require(paths(tests, "PBXSourcesBuildPhase") == {str(p.relative_to(ROOT)) for p in (ROOT / "Tests/CodexSwoopCoreTests").glob("*.swift")}, "all XCTest sources registered")
    required_resources = {"Resources/Assets.xcassets",
        "Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png",
        "Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@2x.png"}
    require(paths(app, "PBXResourcesBuildPhase") == required_resources, "same resource phase for Debug/Release/Archive")
    for target in [app, tests]:
        require(all(objects[i]["productName"] == "CodexSwoopCore" for i in target["packageProductDependencies"]), "existing local core product")
    project_config = configurations(objects[project["rootObject"]])
    require(set(project_config) == {"Debug", "Release"}, "Debug and Release configurations")
    for settings in project_config.values():
        require(settings["MACOSX_DEPLOYMENT_TARGET"] == "14.0", "macOS 14 minimum")
        require(settings["SWIFT_VERSION"] == "6.0" and settings["SDKROOT"] == "macosx", "Swift 6/macOS SDK")
    require(project_config["Release"]["ONLY_ACTIVE_ARCH"] == "NO", "Release builds standard architectures")
    require(project_config["Release"]["SWIFT_OPTIMIZATION_LEVEL"] == "-O", "Release optimization")
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    for settings in configurations(app).values():
        require(settings["PRODUCT_BUNDLE_IDENTIFIER"] == info["CFBundleIdentifier"], "bundle identifier consistency")
        require(settings["MARKETING_VERSION"] == info["CFBundleShortVersionString"] and settings["CURRENT_PROJECT_VERSION"] == info["CFBundleVersion"], "version consistency")
        require(settings["INFOPLIST_FILE"] == "Resources/Info.plist", "explicit app plist")
        require(settings["ENABLE_HARDENED_RUNTIME"] == "YES", "hardened runtime configuration")
        require("CODE_SIGN_ENTITLEMENTS" not in settings, "no new entitlement file")
        require(settings["COMBINE_HIDPI_IMAGES"] == "NO", "preserve raw Menu Bar PNG payloads")
    for settings in configurations(tests).values():
        require(not settings.get("TEST_HOST") and not settings.get("BUNDLE_LOADER"), "XCTest never launches application host")
    require(info["LSMinimumSystemVersion"] == "14.0" and info["LSUIElement"] is True, "menu bar app deployment")
    require(info["NSPrincipalClass"] == "NSApplication", "AppKit integration")
    require(info["CFBundleLocalizations"] == ["en", "ru", "uz-Latn"], "compiled localization declarations")
    require("platforms: [.macOS(.v14)]" in (ROOT / "Package.swift").read_text(), "SwiftPM minimum matches")
    # LocalizationCatalog.swift is compiled into the shared core, not a runtime JSON dependency.
    require((ROOT / "Sources/CodexSwoopCore/LocalizationCatalog.swift").is_file(), "compiled localization catalog")
    scheme = ET.parse(ROOT / "CodexSwoop.xcodeproj/xcshareddata/xcschemes/CodexSwoop.xcscheme").getroot()
    testables = scheme.findall("./TestAction/Testables/TestableReference")
    require(len(testables) == 1 and testables[0].get("skipped") == "NO", "shared scheme executes XCTest")
    require(testables[0].find("BuildableReference").get("BlueprintName") == "CodexSwoopCoreTests", "correct XCTest target")
    require(scheme.find("ArchiveAction").get("buildConfiguration") == "Release", "Release archive")
    if args.bundle:
        bundle = args.bundle.resolve()
        actual = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        for key in ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "CFBundleLocalizations", "LSUIElement", "NSPrincipalClass"]:
            require(actual.get(key) == info[key], "bundle plist mismatch: " + key)
        require(not any(k.startswith("CodexSwoopTest") for k in actual), "no QA fixture keys")
        binary = bundle / "Contents/MacOS/CodexSwoop"
        require(binary.is_file(), "bundle executable")
        for name in ["AppIcon.icns", "MenuBarIcon.png", "MenuBarIcon@2x.png"]:
            require((bundle / "Contents/Resources" / name).is_file(), "bundle resource: " + name)
        selected_sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
        load_commands = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
        stamps = re.findall(r"\bminos\s+([\d.]+)\s+sdk\s+([\d.]+)", load_commands)

        def version(value):
            numbers = [int(v) for v in value.split(".")]
            while numbers and numbers[-1] == 0:
                numbers.pop()
            return numbers

        require(bool(stamps), "Mach-O build-version commands present")
        for minimum, sdk in stamps:
            require(version(minimum) == version(info["LSMinimumSystemVersion"]), "Mach-O deployment target matches plist")
            require(version(sdk) == version(selected_sdk), "Mach-O SDK stamp matches selected SDK " + selected_sdk)
        print("PASS bundle plist, executable, resources and Mach-O minimum/SDK stamps: " + selected_sdk)
    print("PASS static Xcode targets, XCTest registration, resources, configuration and deployment consistency (not a native build)")


if __name__ == "__main__":
    main()
