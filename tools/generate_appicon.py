from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SVG_PATH = Path(__file__).resolve().parent / "freddie-icon.svg"
APPICON_DIR = ROOT / "ReadPaper" / "Assets.xcassets" / "AppIcon.appiconset"
CONTENTS_JSON = APPICON_DIR / "Contents.json"

OUTPUT_NAME = "freddie-appicon"


def parse_size(size_str: str) -> int:
    return int(size_str.split("x")[0])


def scale_factor(scale_str: str) -> int:
    return int(scale_str.removesuffix("x"))


def build_filename(base_size: int, scale: int) -> str:
    if scale == 1:
        return f"{OUTPUT_NAME}_{base_size}x{base_size}.png"
    return f"{OUTPUT_NAME}_{base_size}x{base_size}@{scale}x.png"


def render_with_cairosvg(output_path: Path, px_size: int) -> bool:
    try:
        import cairosvg  # type: ignore
    except ImportError:
        return False

    cairosvg.svg2png(
        url=str(SVG_PATH),
        write_to=str(output_path),
        output_width=px_size,
        output_height=px_size,
    )
    return True


def render_with_rsvg(output_path: Path, px_size: int) -> bool:
    executable = shutil.which("rsvg-convert")
    if executable is None:
        return False

    subprocess.run(
        [
            executable,
            "-w",
            str(px_size),
            "-h",
            str(px_size),
            str(SVG_PATH),
            "-o",
            str(output_path),
        ],
        check=True,
    )
    return True


def render_png(output_path: Path, px_size: int) -> None:
    if render_with_cairosvg(output_path, px_size):
        return
    if render_with_rsvg(output_path, px_size):
        return
    raise SystemExit("Neither cairosvg nor rsvg-convert is available to render the app icon.")


def main() -> None:
    if not SVG_PATH.exists():
        raise SystemExit(f"SVG not found: {SVG_PATH}")
    if not CONTENTS_JSON.exists():
        raise SystemExit(f"Contents.json not found: {CONTENTS_JSON}")

    APPICON_DIR.mkdir(parents=True, exist_ok=True)

    data = json.loads(CONTENTS_JSON.read_text(encoding="utf-8"))
    images = data.get("images", [])

    for image in images:
        size_str = image.get("size")
        scale_str = image.get("scale")
        idiom = image.get("idiom")
        if idiom != "mac" or not size_str or not scale_str:
            continue

        base_size = parse_size(size_str)
        scale = scale_factor(scale_str)
        px_size = base_size * scale
        filename = build_filename(base_size, scale)
        output_path = APPICON_DIR / filename

        render_png(output_path, px_size)
        image["filename"] = filename

    CONTENTS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("Freddie app icon PNGs generated and Contents.json updated.")


if __name__ == "__main__":
    main()
