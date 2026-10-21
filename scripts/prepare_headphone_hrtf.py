#!/usr/bin/env python3
"""Extract frontal horizontal HRIRs from SOFA/CIPIC; requires numpy and h5py.
Run in a disposable venv, e.g. /tmp/abc-hrtf-tools/bin/python scripts/prepare_headphone_hrtf.py.
No runtime download or Python dependency is added to the app.
"""
import hashlib
import json
from pathlib import Path
import tempfile
import urllib.request
import h5py
import numpy as np

root = Path(__file__).resolve().parents[1]
profiles = []
for name, subject in [('a', '003'), ('b', '008'), ('c', '021')]:
    url = f'https://sofacoustics.org/data/database/cipic/subject_{subject}.sofa'
    raw = urllib.request.urlopen(url, timeout=30).read()
    path = Path(tempfile.gettempdir()) / f'abc-cipic-{subject}.sofa'
    path.write_bytes(raw)
    with h5py.File(path, 'r') as data:
        assert float(data['Data.SamplingRate'][0]) == 44100
        assert np.all(data['Data.Delay'][:] == 0)
        positions = data['SourcePosition'][:]
        azimuth = (positions[:, 0] + 180) % 360 - 180
        # SOFA positive azimuth is LEFT; app positive azimuth is RIGHT.
        indices = np.where((abs(positions[:, 1]) < 1e-6) & (abs(azimuth) <= 80.01))[0]
        indices = sorted(indices, key=lambda i: -azimuth[i])
        ir = data['Data.IR'][:]
        # One scale for the complete subject, both ears/all directions. Equalize
        # horizontal mean broadband energy between profiles, never each ear or
        # each direction separately: relative ILD/spectral cues must survive.
        energy = np.mean(np.sum(ir[indices] ** 2, axis=2))
        scale = (0.5 / energy) ** 0.5
        directions = [dict(azimuth=round(float(-azimuth[i]), 6),
                           left=[float(f'{v * scale:.8g}') for v in ir[i, 0]],
                           right=[float(f'{v * scale:.8g}') for v in ir[i, 1]]) for i in indices]
        assert len(directions) == 25
        profiles.append(dict(id=name, subject=f'CIPIC {subject}', source=url,
                             sourceSHA256=hashlib.sha256(raw).hexdigest(), normalizationScale=float(scale), directions=directions))
result = dict(copyright='Copyright (c) 2001 The Regents of the University of California. All Rights Reserved.',
              sampleRate=44100, profiles=profiles)
output = root / 'Sources/Audio/HRTF/HeadphoneHRTF.json'
output.write_text(json.dumps(result, separators=(',', ':')) + '\n')
print(f'{output}: {output.stat().st_size} bytes; 3 profiles × 25 directions × 2 ears × 200 taps')
