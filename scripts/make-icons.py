#!/usr/bin/env python3
"""Draw the Watch Remote app icon: teal to indigo, a simple watch mark."""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024


def icon() -> Image.Image:
    image = Image.new("RGB", (SIZE, SIZE))
    pixels = image.load()
    teal = (15, 140, 148)
    indigo = (38, 46, 120)
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x + y) / (2 * (SIZE - 1))
            pixels[x, y] = tuple(int(teal[i] + (indigo[i] - teal[i]) * t) for i in range(3))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((392, 250, 632, 774), radius=120, outline=(255, 255, 255), width=36)
    draw.ellipse((452, 392, 572, 512), outline=(255, 255, 255), width=28)
    draw.line((512, 452, 512, 400), fill=(255, 255, 255), width=18)
    draw.line((512, 452, 560, 480), fill=(255, 255, 255), width=18)
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
