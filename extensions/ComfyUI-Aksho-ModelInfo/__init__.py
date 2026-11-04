# Aksho ModelInfo: a read-only ComfyUI route the Atelier client uses to route
# each model to the correct workflow. The browser can't read the model files,
# so this reads their safetensors headers server-side and classifies:
#
#   builtin  - checkpoint bundles its own CLIP (normal SDXL / SD1.5)
#   anima    - Anima DiT (Cosmos-Predict2 family, Qwen3-0.6B encoder)
#   zimage   - Z-Image DiT (Lumina2 family, Qwen3-4B encoder, split files)
#   krea2    - Krea2 DiT (Qwen3-VL-4B encoder, split files)
#   moss     - MOSS-Image DiT (Qwen3.5-9B encoder, FLUX.2 VAE, split files;
#              ComfyUI v0.42.0 and later)
#   unknown  - no bundled text encoder and an unrecognized architecture
#
# Scans models/checkpoints (all-in-one files) and models/diffusion_models
# (UNet-only split distributions). A second route, /aksho/lora-info, reads
# models/loras the same way: which model family each LoRA was made for and
# the trigger words its training wrote down, so the Atelier offers a LoRA only
# beside a checkpoint it fits and adds its words when its slot is armed. Architectures are identified by ComfyUI's
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
    if cfg.unet_config.get("image_model") == "moss_image":
        return "moss"
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


# A LoRA cannot go through model_detection (it is a patch, not a model), so
# its family comes from what its trainer wrote down, then from the shape of
# its keys. Families match the Atelier's: sdxl (Illustrious, NoobAI, Pony and
# SDXL itself), sd15, anima, zimage, krea2, moss; anything else is unknown.
_LORA_FAMILY_WORDS = (
    ("stable-diffusion-xl", "sdxl"), ("sdxl", "sdxl"), ("animagine", "sdxl"), ("illustrious", "sdxl"), ("noobai", "sdxl"), ("pony", "sdxl"),
    ("moss", "moss"),
    ("z-image", "zimage"), ("zimage", "zimage"), ("z_image", "zimage"),
    ("krea", "krea2"),
    ("anima", "anima"),
    ("stable-diffusion-v1", "sd15"), ("sd_v1", "sd15"), ("sd-v1", "sd15"),
)


def _lora_family(meta, keys):
    """The family a LoRA was trained for: its metadata first (kohya, ai-toolkit
    and Civitai's trainer all write one of these), then its keys."""
    said = " ".join(str(meta.get(k, "")) for k in ("modelspec.architecture", "ss_base_model_version", "ss_sd_model_name")).lower()
    for word, family in _LORA_FAMILY_WORDS:
        if word in said:
            return family
    flat = [k.replace(".", "_") for k in keys]
    # MOSS-Image blocks: the same tensors model_detection keys on.
    if any("ffn_up_gate" in k or "shared_block_modulation" in k for k in flat):
        return "moss"
    # Anima (Cosmos-Predict2 blocks) and Z-Image (NextDiT refiners).
    if any("adaln_modulation_self_attn" in k for k in flat):
        return "anima"
    if any("noise_refiner" in k or "context_refiner" in k for k in flat):
        return "zimage"
    # A UNet LoRA: SDXL trains two text encoders and has no attention in its
    # first down block; SD1.5 trains one and has.
    unet = [k for k in flat if k.startswith(("lora_unet_", "unet_", "lora_te", "te1_", "te2_", "text_encoder"))]
    if unet:
        if any(k.startswith(("lora_te1_", "lora_te2_", "te1_", "te2_", "text_encoder_2_")) for k in unet):
            return "sdxl"
        if any("down_blocks_0_attentions" in k or "input_blocks_1_1_" in k or "input_blocks_2_1_" in k for k in unet):
            return "sd15"
        if any(k.startswith("lora_te_") for k in unet):
            return "sd15"
        return "sdxl"
    return "unknown"


def _lora_triggers(meta):
    """The words that call a LoRA up, as its trainer recorded them: the
    modelspec trigger phrase, or for Civitai's own trainer (which writes no
    phrase) the title it gives the file, which is the trained word."""
    words = [w.strip() for w in str(meta.get("modelspec.trigger_phrase", "")).split(",") if w.strip()]
    if not words and "civitai_gpu_architecture" in meta:
        title = str(meta.get("modelspec.title", "")).strip()
        if title and " " not in title and len(title) <= 64:
            words = [title]
    return words[:8]


@PromptServer.instance.routes.get("/aksho/lora-info")
async def lora_info(request):
    result = {}
    for name in folder_paths.get_filename_list("loras"):
        if not name.lower().endswith(".safetensors") or name in result:
            continue
        try:
            header = _read_header(folder_paths.get_full_path("loras", name))
            meta = header.get("__metadata__") or {}
            keys = [k for k in header if k != "__metadata__"]
            result[name] = {"family": _lora_family(meta, keys), "triggerWords": _lora_triggers(meta)}
        except Exception as err:
            print("[AKSHO MODELINFO] Failed to read LoRA header for", name, "-", err)
    return web.json_response(result)


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


# No graph nodes; this extension only adds the two routes above.
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
