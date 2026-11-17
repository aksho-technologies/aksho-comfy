# Aksho Repaint: the two steps the Atelier's Inpaint needs that ComfyUI's own nodes cannot do (CEO 2026-11-15).
# The method is the canon detail fix (Atelier handbook, canon-detail-fix, sections 4.2 and 4.6), moved into the
# graph so the content check scores the finished picture.
#
#   AkshoHarmonicFill   fills a zone from the picture around it: a harmonic (Laplace) interpolation solved coarse
#                       to fine at 1/8, 1/4, 1/2 and full size, plus grain quilted from the ring around the zone.
#                       Nothing inside the zone comes from what was there, so no trace of the old shape survives.
#                       Pixels under `keep` give no value and take none.
#   AkshoSeamlessPaste  pastes a repaint back into the picture: lo(new, 2) + hp(new) * gain inside the drawn mask,
#                       feathered over `feather` px outside it; `gain` matches its grain to the picture's own around
#                       the mask. `tone_match` brings its lightness to `base`'s (the picture itself) where both show
#                       the same material, and carries that light into the rest, so a thing the repaint moved or
#                       removed never votes its old light back in (2026-11-16, G2 note 6). Outside the feather every
#                       pixel is the destination's, exactly. `keep` is never written: its core (eroded 1 px) stays
#                       the picture's exactly, and the repaint fades into it over about 8 px, so a tone step at the
#                       keep's edge spreads instead of reading as a line (2026-11-16, G2 note 5).
#
# All pixel sizes are the picture's own. Images are ComfyUI IMAGE tensors (B, H, W, C, 0-1), masks MASK (B, H, W).

import torch
import torch.nn.functional as F

_FOUR = torch.tensor([[0.0, 1.0, 0.0], [1.0, 0.0, 1.0], [0.0, 1.0, 0.0]])


def _kernel(sigma, device):
    r = max(1, int(round(3 * sigma)))
    x = torch.arange(-r, r + 1, dtype=torch.float32, device=device)
    k = torch.exp(-(x * x) / (2 * sigma * sigma))
    return k / k.sum(), r


def _blur(t, sigma):
    """Gaussian blur of an (N, C, H, W) tensor, separable, edges replicated."""
    if sigma <= 0:
        return t
    k, r = _kernel(sigma, t.device)
    c = t.shape[1]
    t = F.pad(t, (r, r, 0, 0), mode="replicate")
    t = F.conv2d(t, k.view(1, 1, 1, -1).repeat(c, 1, 1, 1), groups=c)
    t = F.pad(t, (0, 0, r, r), mode="replicate")
    return F.conv2d(t, k.view(1, 1, -1, 1).repeat(c, 1, 1, 1), groups=c)


def _grow(m, px):
    """Grows a (1, 1, H, W) 0/1 mask by px, alternating square and cross steps (an octagon, near round)."""
    for i in range(int(px)):
        if i % 2 == 0:
            m = F.max_pool2d(m, 3, stride=1, padding=1)
        else:
            p = F.pad(m, (1, 1, 1, 1))
            m = torch.maximum(m, torch.maximum(torch.maximum(p[..., :-2, 1:-1], p[..., 2:, 1:-1]), torch.maximum(p[..., 1:-1, :-2], p[..., 1:-1, 2:])))
    return m


def _distance_outside(m, limit):
    """Distance in px from a (1, 1, H, W) 0/1 mask, counted up to `limit` (beyond it: limit + 1)."""
    d = torch.full_like(m, float(limit + 1))
    d[m > 0.5] = 0
    cur = m
    for step in range(1, int(limit) + 1):
        cur = _grow(cur, 1) if step % 2 else torch.maximum(cur, _grow_cross(cur))
        d = torch.where((cur > 0.5) & (d > step), torch.full_like(d, float(step)), d)
    return d


def _grow_cross(m):
    p = F.pad(m, (1, 1, 1, 1))
    return torch.maximum(torch.maximum(p[..., :-2, 1:-1], p[..., 2:, 1:-1]), torch.maximum(p[..., 1:-1, :-2], p[..., 1:-1, 2:]))


def _lab(rgb):
    """sRGB (N, 3, H, W), 0-1, to CIE Lab (D65): L 0-100."""
    lin = torch.where(rgb <= 0.04045, rgb / 12.92, ((rgb.clamp_min(0) + 0.055) / 1.055) ** 2.4)
    r, g, b = lin[:, 0:1], lin[:, 1:2], lin[:, 2:3]
    x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
    def f(t):
        return torch.where(t > 216 / 24389, t.clamp_min(1e-12) ** (1 / 3), (24389 / 27 * t + 16) / 116)
    fx, fy, fz = f(x), f(y), f(z)
    return torch.cat([116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)], 1)


def _rgb(lab):
    """CIE Lab (D65) back to sRGB (N, 3, H, W), 0-1."""
    fy = (lab[:, 0:1] + 16) / 116
    fx, fz = fy + lab[:, 1:2] / 500, fy - lab[:, 2:3] / 200
    def finv(t):
        return torch.where(t ** 3 > 216 / 24389, t ** 3, (116 * t - 16) / (24389 / 27))
    x, y, z = finv(fx) * 0.95047, finv(fy), finv(fz) * 1.08883
    lin = torch.cat([
        3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
        -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
        0.0556434 * x - 0.2040259 * y + 1.0572252 * z,
    ], 1).clamp(0, 1)
    return torch.where(lin <= 0.0031308, 12.92 * lin, 1.055 * lin.clamp_min(1e-12) ** (1 / 2.4) - 0.055)


def _agreed_light(orig, new, region):
    """The L offset that brings the repaint's lightness to the picture's (G2 note 6, 2026-11-16). Only pixels in `region`
    where both show the same material (a*, b* within 4) vote; each votes the picture's smoothed L minus the repaint's.
    The votes spread to their neighbours by normalized convolution (10 px) and fade to nothing where none voted nearby,
    so a part the repaint drew anew keeps its own light: a ratio carried 40 px from the mask's edge blew a relit face
    out to L 57 from 25. A thing the repaint moved or removed has another colour, so it never votes its old light back
    in; the plain base blur did, and left the old shape as a dark or light ghost."""
    agree = (region & ((orig[:, 1:2] - new[:, 1:2]).abs() < 4) & ((orig[:, 2:3] - new[:, 2:3]).abs() < 4)
             & (orig[:, 0:1] > 2) & (new[:, 0:1] > 2))
    a = agree.float()
    vote = torch.where(agree, _blur(orig[:, 0:1], 3.0) - _blur(new[:, 0:1], 3.0), torch.zeros_like(a))
    den = _blur(a, 10.0)
    offset = _blur(vote * a, 10.0) / den.clamp_min(1e-6) * (den / 0.05).clamp(0, 1)
    return offset.clamp(-25, 25)


def _mask_at(mask, b, h, w):
    """Mask `b` as (1, 1, H, W), resized to h x w if it was drawn at another size."""
    m = mask[min(b, mask.shape[0] - 1)] if mask.dim() == 3 else mask
    m = m.float().view(1, 1, m.shape[-2], m.shape[-1])
    if m.shape[-2:] != (h, w):
        m = F.interpolate(m, size=(h, w), mode="bilinear", align_corners=False)
    return m


def _box(m, pad, h, w):
    ys, xs = torch.nonzero(m[0, 0] > 0.5, as_tuple=True)
    if ys.numel() == 0:
        return None
    return (max(0, int(ys.min()) - pad), min(h, int(ys.max()) + pad + 1), max(0, int(xs.min()) - pad), min(w, int(xs.max()) + pad + 1))


def harmonic_fill(img, zone, walls, texture=1.0, seed=0):
    """img (1, 3, H, W); zone and walls (1, 1, H, W) 0/1. Returns img with the zone filled from around it."""
    zone = zone * (1 - walls)
    h, w = img.shape[-2:]
    span = _box(zone, 0, h, w)
    if span is None:
        return img
    # Work on the zone's box with room around it: the fill reads the ring of picture just outside the zone.
    y0, y1, x0, x1 = span
    pad = max(16, (max(y1 - y0, x1 - x0) + 1) // 2)
    y0, y1, x0, x1 = max(0, y0 - pad), min(h, y1 + pad), max(0, x0 - pad), min(w, x1 + pad)
    crop, z, wl = img[..., y0:y1, x0:x1], zone[..., y0:y1, x0:x1], walls[..., y0:y1, x0:x1]
    ch, cw = crop.shape[-2:]
    ring = (_grow(z, 3) > 0.5) & (z < 0.5) & (wl < 0.5)
    if not bool(ring.any()):
        ring = (z < 0.5) & (wl < 0.5)
        if not bool(ring.any()):
            return img
    start = crop[:, :, ring[0, 0]].mean(dim=2).view(1, -1, 1, 1)
    x = torch.where(z > 0.5, start.expand_as(crop), crop)
    four = _FOUR.to(img.device).view(1, 1, 3, 3)
    # Coarse to fine (a single full-size relaxation never settles on a big zone: it left a dark middle).
    for f in (8, 4, 2, 1):
        n_h, n_w = max(2, ch // f), max(2, cw // f)
        zs = F.interpolate(z, size=(n_h, n_w), mode="bilinear", align_corners=False) > 0.5
        ws = F.interpolate(wl, size=(n_h, n_w), mode="bilinear", align_corners=False) > 0.5
        zs = zs & ~ws
        valid = (~ws).float()
        den = F.conv2d(F.pad(valid, (1, 1, 1, 1), mode="replicate"), four).clamp_min(1e-3)
        xs = F.interpolate(x, size=(n_h, n_w), mode="bilinear", align_corners=False)
        cs = F.interpolate(crop, size=(n_h, n_w), mode="bilinear", align_corners=False)
        xs = torch.where(zs, xs, cs)
        kc = four.repeat(xs.shape[1], 1, 1, 1)
        for _ in range(400):
            nb = F.conv2d(F.pad(xs * valid, (1, 1, 1, 1), mode="replicate"), kc, groups=xs.shape[1]) / den
            xs = torch.where(zs, nb, xs)
        up = F.interpolate(xs, size=(ch, cw), mode="bilinear", align_corners=False)
        x = torch.where(z > 0.5, up, crop)
    # Grain: the picture's own high frequencies, quilted from 8 px patches of the ring and scaled to its strength.
    if texture > 0:
        hp = crop - _blur(crop, 2.0)
        band = (_grow(z, 8) > 0.5) & (z < 0.5) & (wl < 0.5)
        P = 8
        ok = F.max_pool2d((~band).float(), P, stride=1) < 0.5
        cand = torch.nonzero(ok[0, 0], as_tuple=False)
        if cand.shape[0] > 0:
            g = torch.Generator(device="cpu").manual_seed(int(seed))
            tile = torch.zeros_like(crop)
            for ty in range(0, ch, P):
                for tx in range(0, cw, P):
                    i = int(torch.randint(0, cand.shape[0], (1,), generator=g))
                    sy, sx = int(cand[i, 0]), int(cand[i, 1])
                    hh, ww = min(P, ch - ty), min(P, cw - tx)
                    tile[..., ty:ty + hh, tx:tx + ww] = hp[..., sy:sy + hh, sx:sx + ww]
            fz = _blur(z, 1.5).clamp(0, 1)
            x = x + tile * fz * float(texture)
    out = img.clone()
    # The grain reaches 2 px past the zone so its edge carries grain too; the walls are never written.
    reach = (z > 0.5) if texture <= 0 else (_grow(z, 2) > 0.5)
    out[..., y0:y1, x0:x1] = torch.where(reach & (wl < 0.5), x, crop)
    return out.clamp(0, 1)


def seamless_paste(dest, src, base, drawn, walls, x, y, feather, tone_match):
    """dest and base (1, 3, H, W); src (1, 3, h, w) placed at x, y; drawn and walls (1, 1, H, W). Returns dest pasted."""
    H, W = dest.shape[-2:]
    h, w = src.shape[-2:]
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(W, x + w), min(H, y + h)
    if x1 <= x0 or y1 <= y0:
        return dest
    new = src[..., y0 - y:y1 - y, x0 - x:x1 - x]
    orig = dest[..., y0:y1, x0:x1]
    b = base[..., y0:y1, x0:x1]
    m = (drawn[..., y0:y1, x0:x1] > 0.5).float()
    wl = (walls[..., y0:y1, x0:x1] > 0.5).float()
    if not bool(m.any()):
        return dest
    # Round the drawn shape (corners and steps show as seams), keeping thin parts it would otherwise lose.
    rounded = torch.maximum((_blur(m, 3.0) > 0.5).float(), m)
    # Weight: 1 on the drawn mask, falling smoothly to 0 at `feather` px outside it; 0 on the walls. The walls' core
    # (eroded 1 px) stays the picture's exactly; the repaint fades into it over about 8 px (a 4 px blur, doubled), so a
    # tone step at the keep's edge spreads out instead of reading as a line (G2 note 5, 2026-11-16: the row-to-row jump
    # there went from 1.7 L to 0.4).
    feather = max(1, int(feather))
    d = _distance_outside(rounded, feather)
    s = (1 - d / feather).clamp(0, 1)
    walls_core = 1 - _grow(1 - wl, 1)
    protect = torch.maximum(walls_core, (_blur(walls_core, 4.0) * 2).clamp(0, 1))
    weight = s * s * (3 - 2 * s) * (1 - protect)
    lo2 = _blur(new, 2.0)
    hp = new - lo2
    # The repaint's grain matched to the picture's own just outside the mask.
    ring = (d > 3) & (d <= feather + 3) & (wl < 0.5)
    core = (_grow(1 - rounded, 6) < 0.5) & (wl < 0.5)
    if not bool(core.any()):
        core = (rounded > 0.5) & (wl < 0.5)
    hp_orig = orig - _blur(orig, 2.0)
    gain = 1.0
    if bool(ring.any()) and bool(core.any()):
        num = hp_orig[:, :, ring[0, 0]].std()
        den = hp[:, :, core[0, 0]].std().clamp_min(1e-4)
        gain = float((num / den).clamp(0.6, 1.4))
    matched = lo2 + hp * gain
    if float(tone_match) > 0:
        # The repaint's lightness brought to the picture's where both agree, as an offset on L: the repaint's own
        # texture and shading ride along unscaled (a gain amplified them into a mottle).
        nl = _lab(matched.clamp(0, 1))
        nl[:, 0:1] = (nl[:, 0:1] + _agreed_light(_lab(b), nl, (s > 0.01) & (wl < 0.5)) * float(tone_match)).clamp(0, 100)
        matched = _rgb(nl)
    out = dest.clone()
    out[..., y0:y1, x0:x1] = orig * (1 - weight) + matched * weight
    return out.clamp(0, 1)


def _nchw(img, b):
    return img[min(b, img.shape[0] - 1)].permute(2, 0, 1).unsqueeze(0).float()


class AkshoHarmonicFill:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image": ("IMAGE",),
                "mask": ("MASK",),
                "texture": ("FLOAT", {"default": 1.0, "min": 0.0, "max": 2.0, "step": 0.05}),
            },
            "optional": {"keep": ("MASK",)},
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "fill"
    CATEGORY = "Aksho"

    def fill(self, image, mask, texture, keep=None):
        outs = []
        for b in range(image.shape[0]):
            img = _nchw(image, b)
            h, w = img.shape[-2:]
            zone = (_mask_at(mask, b, h, w) > 0.5).float()
            walls = (_mask_at(keep, b, h, w) > 0.5).float() if keep is not None else torch.zeros_like(zone)
            outs.append(harmonic_fill(img, zone, walls, texture=texture, seed=b))
        return (torch.cat(outs).permute(0, 2, 3, 1),)


class AkshoSeamlessPaste:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "destination": ("IMAGE",),
                "source": ("IMAGE",),
                "base": ("IMAGE",),
                "mask": ("MASK",),
                "x": ("INT", {"default": 0, "min": 0, "max": 16384}),
                "y": ("INT", {"default": 0, "min": 0, "max": 16384}),
                "feather": ("INT", {"default": 8, "min": 1, "max": 128}),
                "tone_match": ("FLOAT", {"default": 1.0, "min": 0.0, "max": 1.0, "step": 0.05}),
            },
            "optional": {"keep": ("MASK",)},
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "paste"
    CATEGORY = "Aksho"

    def paste(self, destination, source, base, mask, x, y, feather, tone_match, keep=None):
        outs = []
        for b in range(destination.shape[0]):
            dest = _nchw(destination, b)
            H, W = dest.shape[-2:]
            bs = _nchw(base, b)
            if bs.shape[-2:] != (H, W):
                raise ValueError(f"Aksho Seamless Paste: base is {bs.shape[-1]}x{bs.shape[-2]}, the picture is {W}x{H}.")
            drawn = (_mask_at(mask, b, H, W) > 0.5).float()
            walls = (_mask_at(keep, b, H, W) > 0.5).float() if keep is not None else torch.zeros_like(drawn)
            outs.append(seamless_paste(dest, _nchw(source, b), bs, drawn, walls, x, y, feather, tone_match))
        return (torch.cat(outs).permute(0, 2, 3, 1),)


NODE_CLASS_MAPPINGS = {"AkshoHarmonicFill": AkshoHarmonicFill, "AkshoSeamlessPaste": AkshoSeamlessPaste}
NODE_DISPLAY_NAME_MAPPINGS = {"AkshoHarmonicFill": "Aksho Harmonic Fill", "AkshoSeamlessPaste": "Aksho Seamless Paste"}
