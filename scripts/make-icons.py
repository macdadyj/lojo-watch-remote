#!/usr/bin/env python3
"""Draw the Watch Remote app icon: teal to indigo, a simple watch mark."""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024


def icon() -> Image.Image:
    image = Image.new("RGB", (SIZE, SIZE))
    pixels = image.load()
    teal = (18, 148, 156)
    indigo = (28, 38, 112)
    for y in range(SIZE):
        for x in range(SIZE):
            blend = (x * 0.35 + y * 0.65) / (SIZE - 1)
            pixels[x, y] = tuple(int(teal[i] + (indigo[i] - teal[i]) * blend) for i in range(3))
    draw = ImageDraw.Draw(image)
    face = (14, 32, 64)
    # A filled case stays readable at 60 pt and inside the round Watch mask.
    draw.rounded_rectangle((340, 188, 684, 836), radius=168, fill=(255, 255, 255))
    draw.rounded_rectangle((388, 236, 636, 788), radius=136, fill=face)
    draw.rounded_rectangle((684, 470, 736, 554), radius=18, fill=(255, 255, 255))
    draw.ellipse((444, 444, 580, 580), outline=(255, 255, 255), width=22)
    draw.line((512, 512, 512, 470), fill=(255, 255, 255), width=16)
    draw.line((512, 512, 548, 540), fill=(255, 255, 255), width=16)
    draw.ellipse((502, 502, 522, 522), fill=(255, 255, 255))
    return image


def write(directory: Path, platform: str) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    icon().save(directory / "AppIcon.png", "PNG")
    contents = """{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "%s",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""" % platform
    (directory / "Contents.json").write_text(contents)
    parent = directory.parent
    (parent / "Contents.json").write_text(
        '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'
    )


def main() -> None:
    write(ROOT / "App/iOS/Assets.xcassets/AppIcon.appiconset", "ios")
    write(ROOT / "App/Watch/Assets.xcassets/AppIcon.appiconset", "watchos")


if __name__ == "__main__":
    main()
