#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path


SIZE = 1024.0
ICON_SCALE = 0.83
ICON_SIZE = SIZE * ICON_SCALE
ICON_ORIGIN = (SIZE - ICON_SIZE) / 2.0


PALETTES = {
    "classic": {
        "backgroundStart": "#142B33",
        "backgroundEnd": "#315159",
        "plateStart": "#FFF4DD",
        "plateEnd": "#F0DFC1",
        "leadingGlow": "#7FCDBE",
        "trailingGlow": "#F18A59",
        "glyph": "#21424A",
        "accent": "#F1794A",
    },
    "sky": {
        "backgroundStart": "#D6EEFF",
        "backgroundEnd": "#B8D4F0",
        "plateStart": "#FFFCF5",
        "plateEnd": "#E6EEF5",
        "leadingGlow": "#69B8F2",
        "trailingGlow": "#F0A870",
        "glyph": "#23475D",
        "accent": "#E67942",
    },
    "mint": {
        "backgroundStart": "#D0F5E8",
        "backgroundEnd": "#B8E8D0",
        "plateStart": "#FFFDF4",
        "plateEnd": "#E6F1E7",
        "leadingGlow": "#6DC8AA",
        "trailingGlow": "#EEA461",
        "glyph": "#26473C",
        "accent": "#DE7834",
    },
    "peach": {
        "backgroundStart": "#FFE4D6",
        "backgroundEnd": "#F0D0B8",
        "plateStart": "#FFF6EE",
        "plateEnd": "#F0DFD2",
        "leadingGlow": "#F2B699",
        "trailingGlow": "#E58A62",
        "glyph": "#5A3F35",
        "accent": "#D86B41",
    },
    "blossom": {
        "backgroundStart": "#FFD6E8",
        "backgroundEnd": "#F0B8D0",
        "plateStart": "#FFF4F8",
        "plateEnd": "#EFDFE8",
        "leadingGlow": "#EEA1C1",
        "trailingGlow": "#F08D67",
        "glyph": "#593847",
        "accent": "#D86451",
    },
    "honey": {
        "backgroundStart": "#FFF0C8",
        "backgroundEnd": "#F0DCA0",
        "plateStart": "#FFFCEC",
        "plateEnd": "#F3E3C0",
        "leadingGlow": "#E4C269",
        "trailingGlow": "#E99854",
        "glyph": "#5B4926",
        "accent": "#D8792E",
    },
    "snow": {
        "backgroundStart": "#F5F5F7",
        "backgroundEnd": "#E8E8EC",
        "plateStart": "#FFFFFF",
        "plateEnd": "#F0F1F5",
        "leadingGlow": "#CAD0DD",
        "trailingGlow": "#D9B29B",
        "glyph": "#3F4652",
        "accent": "#C96C47",
    },
    "lavender": {
        "backgroundStart": "#E8DEFF",
        "backgroundEnd": "#D4C4F0",
        "plateStart": "#FBF6FF",
        "plateEnd": "#ECE4F5",
        "leadingGlow": "#BEA6ED",
        "trailingGlow": "#F0A36B",
        "glyph": "#473A5D",
        "accent": "#D76E4B",
    },
    "slate": {
        "backgroundStart": "#1A2635",
        "backgroundEnd": "#4B6882",
        "plateStart": "#F3F6FA",
        "plateEnd": "#D8E0E8",
        "leadingGlow": "#7DA5C2",
        "trailingGlow": "#E3A06B",
        "glyph": "#243647",
        "accent": "#D37249",
    },
    "grove": {
        "backgroundStart": "#1D2E23",
        "backgroundEnd": "#4D6B56",
        "plateStart": "#F5F1E6",
        "plateEnd": "#DEE4D5",
        "leadingGlow": "#7DB08F",
        "trailingGlow": "#E39A67",
        "glyph": "#294034",
        "accent": "#D56F45",
    },
    "ember": {
        "backgroundStart": "#33201D",
        "backgroundEnd": "#7A4B42",
        "plateStart": "#FAEFE6",
        "plateEnd": "#E8D7C8",
        "leadingGlow": "#D48E6C",
        "trailingGlow": "#F1A05A",
        "glyph": "#4A2F2A",
        "accent": "#E16A38",
    },
    "coral": {
        "backgroundStart": "#FFD0D6",
        "backgroundEnd": "#F0B8C0",
        "plateStart": "#FFF6F4",
        "plateEnd": "#F2DFDF",
        "leadingGlow": "#F29AA9",
        "trailingGlow": "#EB8F62",
        "glyph": "#5A3840",
        "accent": "#DB6C49",
    },
}


CONTENTS_JSON = {
    "images": [
        {
            "filename": "icon.svg",
            "idiom": "universal",
        }
    ],
    "info": {
        "author": "xcode",
        "version": 1,
    },
    "properties": {
        "preserves-vector-representation": True,
        "template-rendering-intent": "original",
    },
}


def fmt(value: float) -> str:
    return f"{value:.2f}".rstrip("0").rstrip(".")


def icon_svg(palette: dict[str, str]) -> str:
    background_corner = ICON_SIZE * 0.209
    plate_corner = ICON_SIZE * 0.192
    shine_corner = ICON_SIZE * 0.172
    shine_width = ICON_SIZE * 0.020

    lead_diameter = ICON_SIZE * 0.384
    trail_diameter = ICON_SIZE * 0.472
    plate_size = ICON_SIZE * 0.708
    shine_size = ICON_SIZE * 0.670
    glyph_diameter = ICON_SIZE * 0.460
    glyph_stroke = ICON_SIZE * 0.160
    dot_diameter = ICON_SIZE * 0.112

    center = SIZE / 2.0

    lead_center_x = center - ICON_SIZE * 0.238
    lead_center_y = center - ICON_SIZE * 0.273
    trail_center_x = center + ICON_SIZE * 0.262
    trail_center_y = center + ICON_SIZE * 0.294

    plate_origin = center - (plate_size / 2.0)
    shine_origin = center - (shine_size / 2.0)

    glyph_center_x = center - ICON_SIZE * 0.004
    glyph_center_y = center
    glyph_radius = glyph_diameter / 2.0
    start_x = glyph_center_x + (glyph_radius * 0.5)
    start_y = glyph_center_y - (glyph_radius * 0.8660254)
    end_x = start_x
    end_y = glyph_center_y + (glyph_radius * 0.8660254)

    dot_radius = dot_diameter / 2.0
    dot_center_x = center + ICON_SIZE * 0.174
    dot_center_y = center

    return f"""<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="{fmt(ICON_ORIGIN)}" y1="{fmt(ICON_ORIGIN)}" x2="{fmt(ICON_ORIGIN + ICON_SIZE)}" y2="{fmt(ICON_ORIGIN + ICON_SIZE)}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{palette["backgroundStart"]}"/>
      <stop offset="1" stop-color="{palette["backgroundEnd"]}"/>
    </linearGradient>
    <linearGradient id="plate" x1="{fmt(plate_origin)}" y1="{fmt(plate_origin)}" x2="{fmt(plate_origin + plate_size)}" y2="{fmt(plate_origin + plate_size)}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{palette["plateStart"]}"/>
      <stop offset="1" stop-color="{palette["plateEnd"]}"/>
    </linearGradient>
    <linearGradient id="shine" x1="{fmt(shine_origin)}" y1="{fmt(shine_origin)}" x2="{fmt(shine_origin + shine_size * 0.73)}" y2="{fmt(shine_origin + shine_size * 0.73)}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
  </defs>

  <rect x="{fmt(ICON_ORIGIN)}" y="{fmt(ICON_ORIGIN)}" width="{fmt(ICON_SIZE)}" height="{fmt(ICON_SIZE)}" rx="{fmt(background_corner)}" fill="url(#bg)"/>
  <circle cx="{fmt(lead_center_x)}" cy="{fmt(lead_center_y)}" r="{fmt(lead_diameter / 2.0)}" fill="{palette["leadingGlow"]}" fill-opacity="0.09"/>
  <circle cx="{fmt(trail_center_x)}" cy="{fmt(trail_center_y)}" r="{fmt(trail_diameter / 2.0)}" fill="{palette["trailingGlow"]}" fill-opacity="0.08"/>

  <rect x="{fmt(plate_origin)}" y="{fmt(plate_origin)}" width="{fmt(plate_size)}" height="{fmt(plate_size)}" rx="{fmt(plate_corner)}" fill="url(#plate)"/>
  <rect x="{fmt(shine_origin)}" y="{fmt(shine_origin)}" width="{fmt(shine_size)}" height="{fmt(shine_size)}" rx="{fmt(shine_corner)}" stroke="url(#shine)" stroke-width="{fmt(shine_width)}"/>

  <path d="M{fmt(start_x)} {fmt(start_y)} A {fmt(glyph_radius)} {fmt(glyph_radius)} 0 1 0 {fmt(end_x)} {fmt(end_y)}" stroke="{palette["glyph"]}" stroke-width="{fmt(glyph_stroke)}" stroke-linecap="round"/>
  <circle cx="{fmt(dot_center_x)}" cy="{fmt(dot_center_y)}" r="{fmt(dot_radius)}" fill="{palette["accent"]}"/>
</svg>
"""


def main() -> None:
    repository_root = Path(__file__).resolve().parent.parent
    assets_root = repository_root / "Cadenza/Resources/Assets.xcassets"

    for variant, palette in PALETTES.items():
        imageset_dir = assets_root / f"AppIconVariant{variant.capitalize()}.imageset"
        imageset_dir.mkdir(parents=True, exist_ok=True)
        (imageset_dir / "icon.svg").write_text(icon_svg(palette), encoding="utf-8")
        (imageset_dir / "Contents.json").write_text(
            json.dumps(CONTENTS_JSON, indent=2) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
