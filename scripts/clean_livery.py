"""Remove airline/operator branding from livery textures (text, logos, flags, registrations).

blender -b --factory-startup -P clean_livery.py -- <models_dir> <out_dir>
Writes: plane_fuselage.png, heli_outer.png, heli_outer_mask.png, heli_back.png, heli_back_mask.png
(mask = white where the new paint is, used to drive metallic/roughness).
"""
import os
import sys

import bpy
import numpy as np

args = sys.argv[sys.argv.index("--") + 1:]
MODELS, OUT = args[0], args[1]
os.makedirs(OUT, exist_ok=True)

HELI_PAINT = (0.80, 0.60, 0.30)    # champagne gold (sRGB)
TEXT_RADIUS = 4                    # plane text strokes are thinner than 2*r
LOGO_RADIUS = 10                   # white crane logo + ring inside navy panels
PAINT_CLOSE_RADIUS = 16            # helicopter: black text strokes < 32 px at 1024


def dilate(m, r):
    """Square max filter of radius r (separable)."""
    out = m.copy()
    for d in range(1, r + 1):
        out[d:] |= m[:-d]
        out[:-d] |= m[d:]
    m2 = out.copy()
    for d in range(1, r + 1):
        out[:, d:] |= m2[:, :-d]
        out[:, :-d] |= m2[:, d:]
    return out


def erode(m, r):
    return ~dilate(~m, r)


def opening(m, r):
    return dilate(erode(m, r), r)


def closing(m, r):
    return erode(dilate(m, r), r)


def load(glb_images, name):
    img = glb_images[name]
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    return px.reshape(h, w, 4)


def save(arr, name):
    h, w = arr.shape[:2]
    img = bpy.data.images.new(name, w, h, alpha=True)
    img.pixels.foreach_set(np.ascontiguousarray(arr, dtype=np.float32).ravel())
    img.filepath_raw = os.path.join(OUT, name)
    img.file_format = "PNG"
    img.save()
    print("SAVED", name, w, h)


def import_images(glb):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(MODELS, glb))
    return bpy.data.images


def paint(arr, mask, rgb):
    out = arr.copy()
    out[mask, 0], out[mask, 1], out[mask, 2] = rgb
    return out


def clean_plane():
    imgs = import_images("a320-200_with_cockpit_ver_viii.glb")
    a = load(imgs, "Image_0")
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    lum = 0.3 * r + 0.59 * g + 0.11 * b
    navy = (b - r > 0.12) & (lum < 0.35)
    white = lum > 0.7
    # thin navy strokes (text) and thin near-black marks (small circled logos), grown 2 px to catch
    # antialiased edges; grey windows are neither navy nor near-black, so they are kept
    dark = lum < 0.3
    thin = (navy & ~opening(navy, TEXT_RADIUS)) | (dark & ~opening(dark, TEXT_RADIUS))
    text = dilate(thin & dilate(white, 3), 2) & ~opening(navy, TEXT_RADIUS) & (lum < 0.85)
    big_navy = opening(navy, TEXT_RADIUS)
    logo = closing(big_navy, LOGO_RADIUS) & ~navy & (lum > 0.4)
    body_white = tuple(float(c) for c in a[white & ~dilate(~white, 3), :3].mean(0))
    navy_mean = tuple(float(c) for c in a[big_navy, :3].mean(0))
    out = paint(paint(a, dilate(text, 1), body_white), logo, navy_mean)
    print("PLANE text px", int(text.sum()), "logo px", int(logo.sum()))
    save(out, "plane_fuselage.png")


def clean_heli():
    imgs = import_images("ec_135.glb")
    for src, name in (("Image_15", "heli_outer"), ("Image_6", "heli_back")):
        a = load(imgs, src)
        rgb = a[..., :3]
        mx, mn = rgb.max(-1), rgb.min(-1)
        sat = (mx - mn) / np.maximum(mx, 1e-4)
        livery = (sat > 0.35) & (mx > 0.15)
        region = closing(livery, PAINT_CLOSE_RADIUS) | livery
        out = paint(a, region, HELI_PAINT)
        mask = np.zeros_like(a)
        mask[..., 3] = 1.0
        mask[region, :3] = 1.0
        print(name, "paint px", int(region.sum()))
        save(out, f"{name}.png")
        save(mask, f"{name}_mask.png")


clean_plane()
clean_heli()
