"""Export named PNG attachments from an XCTest result."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

LANGUAGES = ("ja", "en", "zh-Hans")
SCENES = ("01-home", "02-date", "03-map", "04-pilgrimage", "05-card")
EXPECTED = {f"store-{language}-{scene}.png" for language in LANGUAGES for scene in SCENES}
EXPECTED.add("paid-01-paywall.png")
SHOT_NAME = re.compile(r"^(store-(?:ja|en|zh-Hans)-\d{2}-[a-z-]+|paid-01-paywall)(?=[_.]|$)")


def normalize(folder):
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    produced = set()
    for test in manifest:
        for attachment in test.get("attachments", []):
            match = SHOT_NAME.match(attachment.get("suggestedHumanReadableName", ""))
            if not match:
                continue
            source = (folder / attachment["exportedFileName"]).resolve()
            name = match[1] + ".png"
            if source.suffix.lower() != ".png" or name not in EXPECTED:
                continue
            if not source.is_relative_to(folder.resolve()) or name in produced:
                raise ValueError(f"Invalid or duplicate screenshot attachment: {name}")
            target = (folder / name).resolve()
            if source != target:
                shutil.copy2(source, target)
            produced.add(name)
    missing = sorted(EXPECTED - produced)
    if missing:
        raise ValueError("Missing screenshot attachments: " + ", ".join(missing))
    return produced


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--review", type=Path, help="App Store Connect IAP review screenshot path")
    parser.add_argument("--normalize-only", action="store_true", help="Use an existing attachment manifest")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if not args.normalize_only:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(args.result),
                        "--output-path", str(args.output)], check=True)
    try:
        count = len(normalize(args.output))
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
    if args.review:
        args.review.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.output / "paid-01-paywall.png", args.review)
    print(f"Exported {count} screenshots to {args.output}")


if __name__ == "__main__":
    main()
