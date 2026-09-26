"""Build the offline FluidR3_GM sample subset used by ABC Studio.

Source: https://github.com/paulrosen/midi-js-soundfonts/tree/gh-pages/FluidR3_GM
FluidR3_GM samples are CC BY 3.0; see Web/SOUNDFONT-ATTRIBUTION.md.
"""
import base64
import json
import pathlib
import re
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Web" / "soundfont"
INSTRUMENTS = (
    "acoustic_grand_piano", "acoustic_guitar_nylon", "violin", "flute",
    "trumpet", "electric_bass_finger", "choir_aahs", "percussion",
)
BASE = "https://raw.githubusercontent.com/paulrosen/midi-js-soundfonts/gh-pages/FluidR3_GM/"

for instrument in INSTRUMENTS:
    source = urllib.request.urlopen(BASE + instrument + "-mp3.js", timeout=90).read().decode()
    match = re.search(r"MIDI\.Soundfont\." + re.escape(instrument) + r"\s*=\s*(\{.*?\})\s*;?\s*$", source, re.S)
    if not match:
        raise ValueError(f"Invalid soundfont source: {instrument}")
    samples = json.loads(re.sub(r",\s*}", "}", match.group(1)))
    folder = ROOT / (instrument + "-mp3")
    folder.mkdir(parents=True, exist_ok=True)
    for pitch, value in samples.items():
        if not re.fullmatch(r"[A-G](?:b)?\d", pitch) or not value.startswith("data:audio/mp3;base64,"):
            raise ValueError(f"Invalid sample: {instrument}/{pitch}")
        (folder / (pitch + ".mp3")).write_bytes(base64.b64decode(value.split(",", 1)[1]))
    print(f"{instrument}: {len(samples)} samples")
