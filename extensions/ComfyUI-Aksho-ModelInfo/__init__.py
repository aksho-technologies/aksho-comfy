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
# actually loads the file as.

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


def _detect_arch(header, keys, prefix, path):
    """Run ComfyUI's model detection on the header shapes and map the config
    class to an Atelier arch label. prefix is 'model.diffusion_model.' for
    checkpoints and '' for UNet-only diffusion_models files (same prefixes
    ComfyUI's own loaders use)."""
    try:
        import comfy.model_detection
        sd = {k: _ShapeOnly(header[k]["shape"]) for k in keys}
        cfg = comfy.model_detection.model_config_from_unet(sd, prefix)
        if cfg is None:
            return "unknown"
        if cfg.unet_config.get("image_model") == "anima":
            return "anima"
        cls = type(cfg).__name__
        if cls in ("ZImage", "ZImagePixelSpace"):
            return "zimage"
        if cls == "Krea2":
            return "krea2"
    except Exception as err:
        print("[AKSHO MODELINFO] detection failed for", path, "-", err)
    return "unknown"


def _classify(path, prefix):
    header = _read_header(path)
    keys = [k for k in header if k != "__metadata__"]
    if prefix and any(any(marker in k for marker in _TEXT_ENCODER_MARKERS) for k in keys):
        return "builtin"
    return _detect_arch(header, keys, prefix, path)


@PromptServer.instance.routes.get("/aksho/checkpoint-clip")
async def checkpoint_clip(request):
    result = {}
    for folder, prefix in (("checkpoints", "model.diffusion_model."), ("diffusion_models", "")):
        for name in folder_paths.get_filename_list(folder):
            if not name.lower().endswith(".safetensors") or name in result:
                continue
            try:
                result[name] = _classify(folder_paths.get_full_path(folder, name), prefix)
            except Exception as err:
                print("[AKSHO MODELINFO] Failed to read header for", name, "-", err)
    return web.json_response(result)


# No graph nodes; this extension only adds the route above.
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
