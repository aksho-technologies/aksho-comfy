# Aksho ModelInfo: a read-only ComfyUI route the Atelier client uses to route
# each model to the correct workflow. The browser can't read the model files,
# so this reads their safetensors headers server-side and classifies:
#
#   builtin  - checkpoint bundles its own CLIP (normal SDXL / SD1.5)
#   anima    - Anima DiT (Cosmos-Predict2 family, Qwen3-0.6B encoder)
#   zimage   - Z-Image DiT (Lumina2 family, Qwen3-4B encoder, split files)
#   krea2    - Krea2 DiT (Qwen3-VL-4B encoder, split files)
#   unknown  - no bundled text encoder and an unrecognized architecture
#
# Scans models/checkpoints (all-in-one files) and models/diffusion_models
# (UNet-only split distributions). Architectures are identified by ComfyUI's
# OWN model_detection run on the file's tensor shapes (authoritative, not a
# key heuristic), so the classification can never drift from what ComfyUI
# actually loads the file as. The tensor prefix is read off the keys rather
# than assumed from the folder: the same architecture ships bare, under 'net.'
# and under 'model.diffusion_model.' depending on who packaged it.

import json
import struct

import folder_paths
from server import PromptServer
from aiohttp import web

_TEXT_ENCODER_MARKERS = ("conditioner", "cond_stage_model", "text_encoders", "text_model")


class _ShapeOnly:
    """Stand-in tensor exposing only .shape, so model_detection can classify a
    checkpoint from its header without loading any weights."""

    __slots__ = ("shape",)

    def __init__(self, shape):
        self.shape = tuple(shape)


def _read_header(path):
    with open(path, "rb") as f:
        header_len = struct.unpack("<Q", f.read(8))[0]
        return json.loads(f.read(header_len))


def _label(cfg):
    """Map a ComfyUI model config to an Atelier arch label, or None."""
    if cfg is None:
        return None
    if cfg.unet_config.get("image_model") == "anima":
        return "anima"
    cls = type(cfg).__name__
    if cls in ("ZImage", "ZImagePixelSpace"):
        return "zimage"
    if cls == "Krea2":
        return "krea2"
    return None


def _prefix_candidates(keys):
    """Prefixes worth trying, read off the keys themselves.

    The tensor prefix cannot be assumed from the folder, and listing the known
    ones is how this broke: the official Anima build prefixes every tensor
    'net.' while a merge of the SAME architecture uses 'model.diffusion_model.',
    so a folder-based guess read the official build as unknown and Atelier
    never listed it. Hardcoding 'net.' would only have postponed the next one.

    A prefix shared by at least half the tensors is a real container rather
    than a coincidence, so collecting those at one, two and three segments
    deep yields '' for a bare UNet, 'net.' for the Cosmos convention, and
    'model.' plus 'model.diffusion_model.' for a checkpoint, without naming
    any of them. A wrong prefix simply fails detection and costs one pass over
    shapes that are already in memory.
    """
    total = len(keys)
    if total == 0:
        return [""]
    counts = {}
    for key in keys:
        parts = key.split(".")
        for depth in (1, 2, 3):
            if len(parts) > depth:
                candidate = ".".join(parts[:depth]) + "."
                counts[candidate] = counts.get(candidate, 0) + 1
    shared = [p for p, c in counts.items() if c * 2 >= total]
    shared.sort(key=lambda p: counts[p], reverse=True)
    return [""] + shared


def _detect_arch(header, keys, path):
    """Run ComfyUI's model detection on the header shapes, trying each prefix
    the keys suggest, and map the first config that identifies to an Atelier
    arch label."""
    try:
        import comfy.model_detection
        sd = {k: _ShapeOnly(header[k]["shape"]) for k in keys}
        for prefix in _prefix_candidates(keys):
            try:
                label = _label(comfy.model_detection.model_config_from_unet(sd, prefix))
            except Exception:
                continue
            if label is not None:
                return label
    except Exception as err:
        print("[AKSHO MODELINFO] detection failed for", path, "-", err)
    return "unknown"


def _classify(path, bundles_encoder):
    """bundles_encoder is True for models/checkpoints, the only folder whose
    files can carry their own text encoder."""
    header = _read_header(path)
    keys = [k for k in header if k != "__metadata__"]
    if bundles_encoder and any(any(marker in k for marker in _TEXT_ENCODER_MARKERS) for k in keys):
        return "builtin"
    return _detect_arch(header, keys, path)


@PromptServer.instance.routes.get("/aksho/checkpoint-clip")
async def checkpoint_clip(request):
    result = {}
    for folder, bundles_encoder in (("checkpoints", True), ("diffusion_models", False)):
        for name in folder_paths.get_filename_list(folder):
            if not name.lower().endswith(".safetensors") or name in result:
                continue
            try:
                result[name] = _classify(folder_paths.get_full_path(folder, name), bundles_encoder)
            except Exception as err:
                print("[AKSHO MODELINFO] Failed to read header for", name, "-", err)
    return web.json_response(result)


# No graph nodes; this extension only adds the route above.
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
