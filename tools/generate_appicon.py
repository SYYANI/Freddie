from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS_DIR = Path(__file__).resolve().parent
SOURCE_CANDIDATES = [
    TOOLS_DIR / "Freddie.png",
    TOOLS_DIR / "freddie-icon.png",
    TOOLS_DIR / "freddie-icon.svg",
]
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


def resolve_source_path() -> Path:
    for candidate in SOURCE_CANDIDATES:
        if candidate.exists():
            return candidate

    expected = ", ".join(path.name for path in SOURCE_CANDIDATES)
    raise SystemExit(f"No app icon source found in tools/. Expected one of: {expected}")


def render_with_cairosvg(source_path: Path, output_path: Path, px_size: int) -> bool:
    try:
        import cairosvg  # type: ignore
    except ImportError:
        return False

    cairosvg.svg2png(
        url=str(source_path),
        write_to=str(output_path),
        output_width=px_size,
        output_height=px_size,
    )
    return True


def render_with_rsvg(source_path: Path, output_path: Path, px_size: int) -> bool:
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
            str(source_path),
            "-o",
            str(output_path),
        ],
        check=True,
    )
    return True


def raster_dimensions(source_path: Path) -> tuple[int, int]:
    executable = shutil.which("sips")
    if executable is None:
        raise SystemExit("sips is required to inspect raster app icon sources on macOS.")

    result = subprocess.run(
        [executable, "-g", "pixelWidth", "-g", "pixelHeight", str(source_path)],
        check=True,
        capture_output=True,
        text=True,
    )

    width = None
    height = None
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("pixelWidth:"):
            width = int(line.split(":", maxsplit=1)[1].strip())
        elif line.startswith("pixelHeight:"):
            height = int(line.split(":", maxsplit=1)[1].strip())

    if width is None or height is None:
        raise SystemExit(f"Unable to read raster dimensions for {source_path}")
    return width, height


def validate_raster_source(source_path: Path) -> None:
    width, height = raster_dimensions(source_path)
    if width != height:
        raise SystemExit(
            f"Raster app icon source must be square to avoid distortion: {source_path.name} is {width}x{height}"
        )
    if width < 1024:
        raise SystemExit(
            f"Raster app icon source must be at least 1024x1024: {source_path.name} is {width}x{height}"
        )


def render_with_sips(source_path: Path, output_path: Path, px_size: int) -> bool:
    executable = shutil.which("sips")
    if executable is None:
        return False

    subprocess.run(
        [executable, "-z", str(px_size), str(px_size), str(source_path), "--out", str(output_path)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return True


def render_png(source_path: Path, output_path: Path, px_size: int) -> None:
    if source_path.suffix.lower() == ".svg":
        if render_with_cairosvg(source_path, output_path, px_size):
            return
        if render_with_rsvg(source_path, output_path, px_size):
            return
        raise SystemExit("Neither cairosvg nor rsvg-convert is available to render the SVG app icon.")

    if render_with_sips(source_path, output_path, px_size):
        return
    raise SystemExit("sips is required to resize raster app icon sources on macOS.")


def main() -> None:
    if not CONTENTS_JSON.exists():
        raise SystemExit(f"Contents.json not found: {CONTENTS_JSON}")

    source_path = resolve_source_path()
    if source_path.suffix.lower() != ".svg":
        validate_raster_source(source_path)

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

        render_png(source_path, output_path, px_size)
        image["filename"] = filename

    CONTENTS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Freddie app icon PNGs generated from {source_path.name} and Contents.json updated.")


if __name__ == "__main__":
    main()
