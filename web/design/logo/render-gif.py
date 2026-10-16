# Renders the four-slot CC logo loop (README.md here) as an animated GIF:
#   python3 -I render-gif.py 3000 raw.gif 50 light   then   gifsicle -O3 raw.gif -o cc-logo-loop.gif
#   python3 -I render-gif.py 3000 raw.gif 50 dark    then   gifsicle -O3 raw.gif -o cc-logo-loop-dark.gif
# Square i sits in slot (i + step) % 4; slots clockwise from top left. Light: squares multiply over the paper.
# Dark: squares screen over the dark paper, as the site does in its dark theme.
import sys, numpy as np
from PIL import Image

N = int(sys.argv[1]); out = sys.argv[2]; fps = int(sys.argv[3])
DARK = len(sys.argv) > 4 and sys.argv[4] == "dark"
PAPER = np.array([0x12, 0x12, 0x11] if DARK else [0xf6, 0xf5, 0xf0]) / 255
INKS = [np.array(c) / 255 for c in ([0x00, 0xa3, 0xe0], [0xe5, 0x00, 0x7e], [0xff, 0xd4, 0x00])]
SLOTS = [(6, 6), (36, 6), (36, 36), (6, 36)]
SQ = 58
# Credits art fills the middle 50% of its canvas (80..240 of 320); the logo's extent 6..94 does the same here.
k = (N * 0.5) / 88
off = N * 0.25 - 6 * k

def ease(t):  # cubic-bezier(.6,0,.3,1)
    lo, hi = 0.0, 1.0
    for _ in range(40):
        m = (lo + hi) / 2
        x = 3 * (1 - m) ** 2 * m * 0.6 + 3 * (1 - m) * m * m * 0.3 + m ** 3
        lo, hi = (m, hi) if x < t else (lo, m)
    m = (lo + hi) / 2
    return 3 * (1 - m) * m * m * 1 + m ** 3  # y with control points 0 and 1

idx = np.arange(N)
def cover(a, b):  # per-pixel coverage of [a, b) on one axis
    return np.clip(np.minimum(idx + 1, b) - np.maximum(idx, a), 0, 1)

def frame(step, t):
    img = np.ones((N, N, 3)) * PAPER
    e = ease(t)
    for i, ink in enumerate(INKS):
        (x0, y0), (x1, y1) = SLOTS[(i + step) % 4], SLOTS[(i + step + 1) % 4]
        x, y = x0 + (x1 - x0) * e, y0 + (y1 - y0) * e
        ax = cover(off + x * k, off + (x + SQ) * k)
        ay = cover(off + y * k, off + (y + SQ) * k)
        a = (ay[:, None] * ax[None, :])[..., None]
        blended = 1 - (1 - img) * (1 - ink) if DARK else img * ink
        img = img + a * (blended - img)
    return Image.fromarray(np.round(img * 255).astype(np.uint8))

MOVE, STEP = 0.7, 1.6
n_move = round(MOVE * fps)
frames, durs = [], []
for s in range(4):
    frames.append(frame(s, 0)); durs.append(round((STEP - MOVE) * 1000))  # hold
    for j in range(1, n_move + 1):
        frames.append(frame(s, j / n_move)); durs.append(round(1000 / fps))
frames = [f.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE) for f in frames]
frames[0].save(out, save_all=True, append_images=frames[1:], duration=durs, loop=0, optimize=True, disposal=1)
print(len(frames), "frames")
