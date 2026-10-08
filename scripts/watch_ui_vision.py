#!/usr/bin/env python3
"""Score Watch screenshots for text size, contrast, clipping, and Speak-bar overlap.

Pixel checks always run. An LLM pass runs only when WATCH_UI_VISION_API_KEY is set,
and it is skipped with a clear log line when the secret is absent.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import struct
import sys
import urllib.error
import urllib.request
import zlib
from pathlib import Path

MIN_TEXT_PX = 10
MIN_CONTRAST = 3.0


def chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def write_png(path: Path, pixels: list[list[tuple[int, int, int]]]) -> None:
    height = len(pixels)
    width = len(pixels[0]) if height else 0
    raw = b"".join(b"\x00" + bytes(channel for pixel in row for channel in pixel) for row in pixels)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def paeth(left: int, up: int, upper_left: int) -> int:
    estimate = left + up - upper_left
    nearest_left = abs(estimate - left)
    nearest_up = abs(estimate - up)
    nearest_upper_left = abs(estimate - upper_left)
    if nearest_left <= nearest_up and nearest_left <= nearest_upper_left:
        return left
    if nearest_up <= nearest_upper_left:
        return up
    return upper_left


def read_png(path: Path) -> list[list[tuple[int, int, int]]]:
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a png")
    offset = 8
    width = height = bit_depth = color_type = interlace = None
    idat = bytearray()
    while offset + 8 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        tag = data[offset + 4 : offset + 8]
        start = offset + 8
        end = start + length
        if end + 4 > len(data):
            raise ValueError(f"{path} png chunk truncated")
        chunk_data = data[start:end]
        if tag == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", chunk_data)
        elif tag == b"IDAT":
            idat.extend(chunk_data)
        elif tag == b"IEND":
            break
        offset = end + 4
    if width is None or height is None or not idat:
        raise ValueError(f"{path} png is missing image data")
    if interlace != 0 or bit_depth != 8 or color_type not in (2, 6):
        raise ValueError(f"{path} png must be 8-bit rgb or rgba, got bit {bit_depth} color {color_type}")
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    expected = height * (stride + 1)
    if len(raw) < expected:
        raise ValueError(f"{path} png data is short")
    previous = bytearray(stride)
    rows: list[list[tuple[int, int, int]]] = []
    cursor = 0
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        scan = bytearray(raw[cursor : cursor + stride])
        cursor += stride
        current = bytearray(stride)
        for index in range(stride):
            left = current[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            value = scan[index]
            if filter_type == 0:
                current[index] = value
            elif filter_type == 1:
                current[index] = (value + left) & 255
            elif filter_type == 2:
                current[index] = (value + up) & 255
            elif filter_type == 3:
                current[index] = (value + ((left + up) // 2)) & 255
            elif filter_type == 4:
                current[index] = (value + paeth(left, up, upper_left)) & 255
            else:
                raise ValueError(f"{path} png filter {filter_type} is unsupported")
        previous = current
        row: list[tuple[int, int, int]] = []
        for x in range(width):
            pixel = index_at(current, x * channels)
            row.append((pixel[0], pixel[1], pixel[2]))
        rows.append(row)
    return rows


def index_at(raw: bytearray, index: int) -> tuple[int, int, int]:
    return raw[index], raw[index + 1], raw[index + 2]


def channel(value: int) -> float:
    srgb = value / 255
    if srgb <= 0.04045:
        return srgb / 12.92
    return ((srgb + 0.055) / 1.055) ** 2.4


def luminance(pixel: tuple[int, int, int]) -> float:
    red, green, blue = pixel
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)


def contrast_ratio(left: tuple[int, int, int], right: tuple[int, int, int]) -> float:
    lighter = max(luminance(left), luminance(right))
    darker = min(luminance(left), luminance(right))
    return (lighter + 0.05) / (darker + 0.05)


def median(values: list[int]) -> int:
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def row_background(row: list[tuple[int, int, int]]) -> tuple[int, int, int]:
    return (
        median([pixel[0] for pixel in row]),
        median([pixel[1] for pixel in row]),
        median([pixel[2] for pixel in row]),
    )


def expects_speak_bar(name: str) -> bool:
    stem = Path(name).stem.lower()
    # Compose, dictate, long text, and the task detail have no bottom Speak bar.
    # Home, sessions, voice, and the shot taken after End do.
    if any(token in stem for token in ("compose", "dictate", "long")):
        return False
    if "session" in stem and "sessions" not in stem:
        return False
    return True


def bar_height(height: int) -> int:
    # 44 pt Speak bar on a ~250 pt watch, in pixels, without swallowing the row above it.
    if height < 220:
        return max(28, height // 6)
    return min(96, max(56, int(round(height * 0.145))))


def text_lines(pixels: list[list[tuple[int, int, int]]]) -> list[dict[str, float]]:
    height = len(pixels)
    width = len(pixels[0]) if height else 0
    text_rows: list[int] = []
    row_ink: dict[int, list[int]] = {}
    row_contrast: dict[int, list[float]] = {}
    for y, row in enumerate(pixels):
        background = row_background(row)
        ink: list[int] = []
        ratios: list[float] = []
        for x, pixel in enumerate(row):
            ratio = contrast_ratio(pixel, background)
            if ratio < 1.2:
                continue
            if abs(luminance(pixel) - luminance(background)) < 0.02 and ratio < 1.35:
                continue
            ink.append(x)
            ratios.append(ratio)
        if len(ink) < 8 or len(ink) > width * 0.62:
            continue
        text_rows.append(y)
        row_ink[y] = ink
        row_contrast[y] = ratios
    lines: list[dict[str, float]] = []
    band: list[int] = []

    def close() -> None:
        if not band:
            return
        ink_x = [x for y in band for x in row_ink[y]]
        ratios = [ratio for y in band for ratio in row_contrast[y]]
        lines.append(
            {
                "top": float(band[0]),
                "bottom": float(band[-1] + 1),
                "height": float(band[-1] - band[0] + 1),
                "left": float(min(ink_x)),
                "right": float(max(ink_x)),
                "contrast": sorted(ratios)[len(ratios) // 2],
            }
        )
        band.clear()

    previous = None
    for y in text_rows:
        # Letter counters leave a few empty rows inside one line. A new line sits further down.
        if previous is not None and y > previous + 4:
            close()
        band.append(y)
        previous = y
    close()
    return lines


def page_background(pixels: list[list[tuple[int, int, int]]]) -> tuple[int, int, int]:
    height = len(pixels)
    width = len(pixels[0])
    samples = [
        pixels[min(4, height - 1)][min(4, width - 1)],
        pixels[min(4, height - 1)][max(0, width - 5)],
        pixels[max(0, height - 5)][min(4, width - 1)],
        pixels[max(0, height - 5)][max(0, width - 5)],
    ]
    return (
        median([pixel[0] for pixel in samples]),
        median([pixel[1] for pixel in samples]),
        median([pixel[2] for pixel in samples]),
    )


def text_span(line: dict[str, float], width: int) -> float:
    return (line["right"] - line["left"]) / width


def is_text_shape(line: dict[str, float], width: int) -> bool:
    """Glyph rows, not a full-width button, hairline, or the rounded-screen mask."""
    span = text_span(line, width)
    if span < 0.08 or span > 0.92:
        return False
    if line["left"] <= 1 and line["right"] >= width - 2:
        return False
    return line["height"] <= 80


def body_lines(shaped: list[dict[str, float]]) -> list[dict[str, float]]:
    """Drop a clipped glyph sliver sitting next to full-size text.

    A scroll view cuts one line at the viewport edge. That band is a few pixels
    tall. It is not a type size. A screen whose text is all that small still fails.
    """
    if len(shaped) < 2:
        return shaped
    heights = sorted(line["height"] for line in shaped)
    median_height = heights[len(heights) // 2]
    kept = [line for line in shaped if line["height"] >= median_height * 0.55]
    return kept or shaped


def score_pixels(pixels: list[list[tuple[int, int, int]]], name: str) -> list[str]:
    height = len(pixels)
    width = len(pixels[0]) if height else 0
    if width < 40 or height < 40:
        return [f"{name}: screenshot is too small ({width}x{height})"]
    lines = text_lines(pixels)
    shaped = body_lines([line for line in lines if is_text_shape(line, width)])
    failures: list[str] = []
    if not shaped:
        return [f"{name}: no readable text"]
    short = [
        line
        for line in shaped
        if line["contrast"] >= MIN_CONTRAST
        and line["height"] < MIN_TEXT_PX
        and line["top"] > height * 0.08
        and line["bottom"] < height * 0.92
    ]
    if short:
        shortest = min(line["height"] for line in short)
        failures.append(f"{name}: text size {shortest:.0f}px is below {MIN_TEXT_PX}px")
    weak = [line for line in shaped if line["height"] >= MIN_TEXT_PX and line["contrast"] < MIN_CONTRAST]
    if weak:
        lowest = min(line["contrast"] for line in weak)
        failures.append(f"{name}: contrast {lowest:.2f} is below {MIN_CONTRAST:.1f}")
    page = page_background(pixels)
    clipped = 0
    top_limit = int(height * 0.18)
    bottom_limit = int(height * 0.78)
    for y in range(top_limit, bottom_limit):
        for x in (0, 1, width - 2, width - 1):
            if contrast_ratio(pixels[y][x], page) >= 4:
                clipped += 1
    if clipped > 8:
        failures.append(f"{name}: text is clipped at the screen edge ({clipped} px)")
    if expects_speak_bar(name):
        # Reply text whose middle sits above the bottom chrome and whose lower edge
        # runs into the Speak bar. The bar's own label sits entirely in that chrome.
        content_limit = height * 0.80
        bar_zone = height * 0.90
        crossing = [
            line
            for line in shaped
            if line["height"] >= MIN_TEXT_PX
            and line["contrast"] >= MIN_CONTRAST
            and (line["top"] + line["bottom"]) / 2 < content_limit
            and line["bottom"] > bar_zone
        ]
        if crossing:
            failures.append(f"{name}: speak bar covers reply text")
    return failures


def score_file(path: Path, name: str | None = None) -> list[str]:
    try:
        pixels = read_png(path)
    except (OSError, ValueError, zlib.error) as error:
        return [f"{path}: {error}"]
    return score_pixels(pixels, name or path.name)


def attachment_names(directory: Path) -> dict[str, str]:
    names: dict[str, str] = {}
    for manifest in directory.rglob("manifest.json"):
        try:
            groups = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for group in groups:
            for item in group.get("attachments", []):
                exported = item.get("exportedFileName")
                suggested = item.get("suggestedHumanReadableName") or ""
                if not exported or not suggested:
                    continue
                stem = suggested.split("_0_")[0]
                if not stem.endswith(".png"):
                    stem = f"{stem}.png"
                names[exported] = stem
    return names


def collect(directory: Path, watch_only: bool) -> list[tuple[Path, str]]:
    files = [path for path in directory.rglob("*") if path.suffix.lower() == ".png" and path.is_file()]
    if watch_only:
        files = [path for path in files if "watch" in path.name.lower() or path.parent.name in {"small", "large"}]
    names = attachment_names(directory)
    chosen: list[tuple[Path, str]] = []
    for path in sorted(files):
        if path.name.startswith("simulator-"):
            print(f"skipped device frame {path.name}")
            continue
        chosen.append((path, names.get(path.name, path.name)))
    return chosen


def llm_failures(images: list[Path]) -> list[str]:
    key = os.environ.get("WATCH_UI_VISION_API_KEY", "").strip()
    if not key:
        print("llm vision: skipped (WATCH_UI_VISION_API_KEY unset)")
        return []
    url = os.environ.get("WATCH_UI_VISION_URL", "https://api.openai.com/v1/chat/completions").strip()
    model = os.environ.get("WATCH_UI_VISION_MODEL", "gpt-4o-mini").strip() or "gpt-4o-mini"
    chosen = images[:6]
    content: list[dict[str, object]] = [
        {
            "type": "text",
            "text": (
                "You score Apple Watch screenshots of Watch Remote. "
                "Reply with JSON only: {\"pass\": true} or {\"pass\": false, \"issues\": [\"...\"]}. "
                "Fail for tiny text, low contrast, clipped or truncated text, or a Speak bar covering replies. "
                "The Speak label itself belongs on the bottom bar."
            ),
        }
    ]
    for path in chosen:
        encoded = base64.standard_b64encode(path.read_bytes()).decode("ascii")
        content.append({"type": "text", "text": path.name})
        content.append({"type": "image_url", "image_url": {"url": f"data:image/png;base64,{encoded}"}})
    payload = {
        "model": model,
        "temperature": 0,
        "messages": [{"role": "user", "content": content}],
    }
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as error:
        return [f"llm vision: request failed ({error.__class__.__name__})"]
    try:
        text = body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return ["llm vision: response had no message"]
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        return ["llm vision: response was not json"]
    try:
        verdict = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return ["llm vision: response was not json"]
    if verdict.get("pass") is True:
        print(f"llm vision: ok ({len(chosen)} screenshots)")
        return []
    issues = verdict.get("issues") or ["llm vision: failed without a reason"]
    return [f"llm vision: {issue}" for issue in issues]


def blank(width: int, height: int, color: tuple[int, int, int]) -> list[list[tuple[int, int, int]]]:
    return [[color for _ in range(width)] for _ in range(height)]


def draw_glyphs(
    pixels: list[list[tuple[int, int, int]]],
    top: int,
    glyph_height: int,
    color: tuple[int, int, int],
    left: int,
) -> None:
    width = len(pixels[0])
    x = left
    while x + 6 < width - 8:
        for y in range(top, top + glyph_height):
            for dx in range(5):
                pixels[y][x + dx] = color
        x += 10


def self_test() -> int:
    failures: list[str] = []
    width, height = 180, 240
    background = (0, 0, 0)
    ink = (255, 255, 255)
    good = blank(width, height, background)
    draw_glyphs(good, 48, 16, ink, 16)
    draw_glyphs(good, 78, 14, (180, 220, 220), 16)
    bar = bar_height(height)
    draw_glyphs(good, height - bar + 8, 14, ink, 40)
    good_fail = score_pixels(good, "scaffold-home.png")
    if good_fail:
        failures.append("good screenshot should pass: " + "; ".join(good_fail))

    teal = blank(width, height, background)
    draw_glyphs(teal, 50, 14, (15, 140, 148), 16)
    draw_glyphs(teal, height - bar + 8, 14, ink, 40)
    teal_fail = score_pixels(teal, "watch-mic.png")
    if teal_fail:
        failures.append("teal on black should pass: " + "; ".join(teal_fail))

    tiny = blank(width, height, background)
    draw_glyphs(tiny, 48, 4, ink, 16)
    draw_glyphs(tiny, 70, 4, ink, 16)
    tiny_fail = score_pixels(tiny, "scaffold-home.png")
    if not any("text size" in item for item in tiny_fail):
        failures.append(f"tiny text should fail size, got {tiny_fail}")

    sliver = blank(width, height, background)
    draw_glyphs(sliver, 40, 3, ink, 16)
    draw_glyphs(sliver, 70, 16, ink, 16)
    draw_glyphs(sliver, height - bar + 8, 14, ink, 40)
    sliver_fail = score_pixels(sliver, "scaffold-restored.png")
    if sliver_fail:
        failures.append("a clipped sliver next to body text should pass: " + "; ".join(sliver_fail))

    faint = blank(width, height, (150, 150, 150))
    draw_glyphs(faint, 48, 16, (168, 168, 168), 16)
    faint_fail = score_pixels(faint, "watch-compose.png")
    if not any("contrast" in item for item in faint_fail):
        failures.append(f"faint text should fail contrast, got {faint_fail}")

    clipped = blank(width, height, background)
    draw_glyphs(clipped, 80, 16, ink, 0)
    clipped_fail = score_pixels(clipped, "watch-compose.png")
    if not any("clipped" in item for item in clipped_fail):
        failures.append(f"edge text should fail clipping, got {clipped_fail}")

    covered = blank(width, height, background)
    draw_glyphs(covered, int(height * 0.62), 70, ink, 16)
    covered_fail = score_pixels(covered, "scaffold-listening.png")
    if not any("speak bar" in item for item in covered_fail):
        failures.append(f"text in the speak bar should fail overlap, got {covered_fail}")

    detail = blank(width, height, background)
    draw_glyphs(detail, height - 30, 16, ink, 16)
    detail_fail = score_pixels(detail, "scaffold-session.png")
    if any("speak bar" in item for item in detail_fail):
        failures.append(f"task detail has no speak bar: {detail_fail}")

    sample = Path("/tmp/watch-ui-vision-roundtrip.png")
    write_png(sample, good)
    reread = read_png(sample)
    if reread[48][16] != ink or score_pixels(reread, "scaffold-home.png"):
        failures.append("png roundtrip changed the good screenshot")

    if os.environ.get("WATCH_UI_VISION_API_KEY", "").strip():
        failures.append("self-test unexpectedly saw an API key")
    skipped = llm_failures([])
    if skipped:
        failures.append("missing key should skip, not fail")

    if failures:
        print("watch ui vision failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("watch ui vision: ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", nargs="?", help="Screenshot directory")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--watch-only", action="store_true")
    parser.add_argument("--no-llm", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.directory:
        print("pass a screenshot directory or --self-test", file=sys.stderr)
        return 2
    directory = Path(args.directory)
    if not directory.is_dir():
        print(f"screenshot directory missing: {directory}", file=sys.stderr)
        return 1
    images = collect(directory, args.watch_only)
    if not images:
        print(f"no screenshots in {directory}", file=sys.stderr)
        return 1
    failures: list[str] = []
    for path, name in images:
        found = score_file(path, name)
        label = f"{path.parent.name}/{name}" if path.parent != directory else name
        prefix = f"{path.parent.name}/" if path.parent != directory else ""
        if found:
            failures.extend(prefix + item for item in found)
        else:
            print(f"readable {prefix}{name}")
    if not failures and not args.no_llm:
        failures.extend(llm_failures([path for path, _name in images]))
    if failures:
        print("watch ui vision failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"watch ui vision: ok ({len(images)} screenshots)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
