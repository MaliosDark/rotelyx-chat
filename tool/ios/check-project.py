#!/usr/bin/env python3
"""Check that the Xcode project file is structurally sound.

    python3 tool/ios/check-project.py

# Why this exists

`project.pbxproj` is edited from a script here, because there is no Xcode on
this machine and a Notification Service Extension target cannot be added by hand
in an editor without getting one of about forty cross-references wrong.

A broken project file does not fail loudly. Xcode refuses to open it, or opens
it with a target silently missing, and the first sign is a build on somebody
else's machine. So the edit is checked: every identifier that is referenced must
be defined, the braces must balance, and every target must have the pieces a
target needs.

This is not a substitute for opening it in Xcode. It is the difference between
finding a mistake here and finding it there.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj"

ID = re.compile(r"\b([0-9A-F]{24})\b")
DEFINITION = re.compile(r"^\t\t([0-9A-F]{24})\b.*= \{", re.M)


def main() -> int:
    text = PROJECT.read_text()
    problems = []

    opens, closes = text.count("{"), text.count("}")
    if opens != closes:
        problems.append(f"braces do not balance: {opens} open, {closes} close")

    p_open, p_close = text.count("("), text.count(")")
    if p_open != p_close:
        problems.append(f"parentheses do not balance: {p_open} open, {p_close} close")

    defined = set(DEFINITION.findall(text))
    dangling = set(ID.findall(text)) - defined

    # CocoaPods writes its xcconfig references in during `pod install`, which
    # runs on macOS. Before that they point at nothing, and that is expected
    # rather than broken, so they are named and excused rather than hidden.
    pods = {
        uuid
        for uuid in dangling
        if re.search(rf"{uuid} /\* Pods-[^*]*\.xcconfig \*/", text)
    }
    dangling -= pods

    # RunnerTests names a Frameworks phase that was never defined. Harmless,
    # because that target has no frameworks, and left alone rather than fixed
    # so that this check reports what it finds instead of what it tidied.
    dangling -= {"331C807E294A63A400263BE5"}

    if dangling:
        problems.append("referenced but never defined: " + ", ".join(sorted(dangling)))

    # The identifiers this repository added. Every one has to resolve: unlike
    # the two exceptions above, a dangling one here is a mistake made here.
    ours = {uuid for uuid in set(ID.findall(text)) if uuid.startswith("E5A1B2C3D4E5F6")}
    missing = ours - defined
    if missing:
        problems.append("added here and not defined: " + ", ".join(sorted(missing)))
    if len(ours) < 20:
        problems.append(f"only {len(ours)} of the added objects are present")

    for section in set(re.findall(r"/\* Begin (\w+) section \*/", text)):
        if text.count(f"/* Begin {section} section */") != 1:
            problems.append(f"{section} section appears more than once")

    targets = re.findall(
        r"^\t\t([0-9A-F]{24}) /\* (\S+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;"
        r"(.*?)^\t\t\};",
        text,
        re.M | re.S,
    )
    if not targets:
        problems.append("no native targets found at all")

    for _, name, body in targets:
        for field in ("buildConfigurationList", "productReference", "productType"):
            if f"{field} = " not in body:
                problems.append(f"target {name} has no {field}")

    names = [name for _, name, _ in targets]
    for wanted in ("Runner", "NotificationService"):
        if wanted not in names:
            problems.append(f"no target named {wanted}")

    if "Embed Foundation Extensions" not in text:
        problems.append("the extension is never embedded into the app")

    for entitlements in (
        "Runner/Runner.entitlements",
        "NotificationService/NotificationService.entitlements",
    ):
        if f"CODE_SIGN_ENTITLEMENTS = {entitlements}" not in text:
            problems.append(f"no target uses {entitlements}")

    for path in (
        "ios/Runner/Runner.entitlements",
        "ios/Runner/PrivacyInfo.xcprivacy",
        "ios/NotificationService/NotificationService.entitlements",
        "ios/NotificationService/NotificationService.swift",
        "ios/NotificationService/Info.plist",
    ):
        if not (ROOT / path).exists():
            problems.append(f"{path} is referenced and missing")

    if problems:
        print("project.pbxproj has problems:\n")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(f"targets:  {', '.join(names)}")
    print(f"objects:  {len(defined)}")
    print()
    print("the project file is structurally sound. Open it in Xcode to be sure.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
