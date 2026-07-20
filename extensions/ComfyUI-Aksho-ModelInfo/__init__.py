# Aksho ModelInfo: a read-only ComfyUI route the Atelier client uses to route
# each checkpoint to the correct workflow. The browser can't read the model
# files, so this reads their safetensors headers server-side and classifies:
#
#   builtin  - checkpoint bundles its own CLIP (normal SDXL / SD1.5)
#   anima    - Anima DiT (Cosmos-Predict2 family, Qwen3-0.6B encoder)
#   unknown  - no bundled text encoder and an unrecognized architecture
#
# Anima is identified by ComfyUI's OWN model_detection run on the file's tensor
# shapes (authoritative, not a key heuristic), so the classification can never
# drift from what ComfyUI actually loads the checkpoint as.

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


def _classify(path):
    header = _read_header(path)
    keys = [k for k in header if k != "__metadata__"]
    if any(any(marker in k for marker in _TEXT_ENCODER_MARKERS) for k in keys):
        return "builtin"
    # No bundled text encoder: ask ComfyUI what architecture this actually is.
    try:
        import comfy.model_detection
        sd = {k: _ShapeOnly(header[k]["shape"]) for k in keys}
        cfg = comfy.model_detection.model_config_from_unet(sd, "model.diffusion_model.")
        if cfg is not None and cfg.unet_config.get("image_model") == "anima":
            return "anima"
    except Exception as err:
        print("[AKSHO MODELINFO] detection failed for", path, "-", err)
    return "unknown"


@PromptServer.instance.routes.get("/aksho/checkpoint-clip")
async def checkpoint_clip(request):
    result = {}
    for name in folder_paths.get_filename_list("checkpoints"):
        if not name.lower().endswith(".safetensors"):
            continue
        try:
            result[name] = _classify(folder_paths.get_full_path("checkpoints", name))
        except Exception as err:
            print("[AKSHO MODELINFO] Failed to read header for", name, "-", err)
    return web.json_response(result)


# No graph nodes; this extension only adds the route above.
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
