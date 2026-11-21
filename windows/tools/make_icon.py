# -*- coding: utf-8 -*-
"""Generate the AirMic Hub application icon (ICO) with Pillow."""
import pathlib

from PIL import Image, ImageDraw


def rounded_rect(size, radius, fill):
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def make(size):
    scale = 4
    big = size * scale
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Mint -> teal -> indigo vertical gradient tile.
    gradient = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(gradient)
    top = (126, 247, 226)
    mid = (94, 234, 212)
    bottom = (124, 134, 248)
    for y in range(big):
        if y < big * 0.55:
            t = y / (big * 0.55)
            color = tuple(int(top[i] + (mid[i] - top[i]) * t) for i in range(3))
        else:
            t = (y - big * 0.55) / (big * 0.45)
            color = tuple(int(mid[i] + (bottom[i] - mid[i]) * t) for i in range(3))
        gdraw.line([(0, y), (big, y)], fill=color + (255,))

    mask = rounded_rect(big, int(big * 0.28), 255)
    image.paste(gradient, (0, 0), mask)

    # Five rounded bars, matching the in-app logo.
    bar_color = (4, 17, 14, 255)
    heights = [0.26, 0.42, 0.58, 0.42, 0.26]
    width = big * 0.075
    gap = big * 0.055
    total = 5 * width + 4 * gap
    start_x = (big - total) / 2
    for index, height in enumerate(heights):
        x0 = start_x + index * (width + gap)
        bar_height = big * height
        y0 = (big - bar_height) / 2
        draw.rounded_rectangle(
            (x0, y0, x0 + width, y0 + bar_height),
            radius=width / 2,
            fill=bar_color,
        )

    return image.resize((size, size), Image.LANCZOS)


root = pathlib.Path(r"C:\Users\chen\Documents\deepseek-harness\default-workspace\windows-app\src\AirMicHub.App\Assets")
root.mkdir(parents=True, exist_ok=True)
sizes = [16, 24, 32, 48, 64, 128, 256]
images = [make(size) for size in sizes]
icon_path = root / "app.ico"
images[-1].save(icon_path, format="ICO", sizes=[(size, size) for size in sizes])
images[-1].save(root / "app.png")
print("wrote", icon_path, icon_path.stat().st_size)
