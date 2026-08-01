"""GLIGEN-XL loader for ComfyUI (SDXL grounded text-box conditioning).

Loads the extracted jiuntian/gligen-xl-1024 grounding weights (diffusers key
names, produced by the aksho extraction script) and exposes them as a standard
GLIGEN output, so the stock GLIGENTextBoxApply node drives it unchanged.

Core's load_gligen cannot load this checkpoint: it groups every fuser inside an
attention module under one two-segment key prefix, which collapses SDXL's
multi-transformer_block attentions (up to 10 fusers per module) into one, and
its flat transformer_index dispatch cannot address the inner blocks. This
loader keeps one fuser per (SpatialTransformer, inner block) and dispatches on
(transformer_index, block_index), both provided in extra_options.
"""
import re

import torch
import torch.nn as nn

import comfy.model_management
import comfy.model_patcher
import comfy.utils
import folder_paths
from comfy.gligen import GatedSelfAttentionDense, Gligen, PositionNet

# Diffusers attention modules in ComfyUI's SDXL execution order. transformer_index
# increments once per SpatialTransformer; block_index indexes the inner
# transformer_blocks within it.
SDXL_TRANSFORMER_ORDER = [
    "down_blocks.1.attentions.0",
    "down_blocks.1.attentions.1",
    "down_blocks.2.attentions.0",
    "down_blocks.2.attentions.1",
    "mid_block.attentions.0",
    "up_blocks.0.attentions.0",
    "up_blocks.0.attentions.1",
    "up_blocks.0.attentions.2",
    "up_blocks.1.attentions.0",
    "up_blocks.1.attentions.1",
    "up_blocks.1.attentions.2",
]

FUSER_KEY_RE = re.compile(r"^(.*\.attentions\.\d+)\.transformer_blocks\.(\d+)\.fuser\.(.+)$")


class GligenXL(Gligen):
    def __init__(self, module_grid, position_net, key_dim):
        flat = [m for blocks in module_grid for m in blocks]
        super().__init__(flat, position_net, key_dim)
        self.module_grid = [list(blocks) for blocks in module_grid]

    def _set_position(self, boxes, masks, positive_embeddings):
        objs = self.position_net(boxes, masks, positive_embeddings)

        def func(x, extra_options):
            ti = extra_options["transformer_index"]
            bi = extra_options.get("block_index", 0)
            module = self.module_grid[ti][bi]
            return module(x, objs.to(device=x.device, dtype=x.dtype))
        return func


def load_gligen_xl(sd):
    grouped = {}
    for key, tensor in sd.items():
        m = FUSER_KEY_RE.match(key)
        if m is None:
            continue
        grouped.setdefault(m.group(1), {}).setdefault(int(m.group(2)), {})[m.group(3)] = tensor

    missing = [p for p in SDXL_TRANSFORMER_ORDER if p not in grouped]
    if missing:
        raise RuntimeError(f"GLIGEN-XL checkpoint is missing fusers for: {missing}")

    key_dim = 768
    module_grid = []
    for prefix in SDXL_TRANSFORMER_ORDER:
        blocks = grouped[prefix]
        block_modules = []
        for bi in sorted(blocks):
            n_sd = blocks[bi]
            query_dim = n_sd["linear.weight"].shape[0]
            key_dim = n_sd["linear.weight"].shape[1]
            d_head = 64
            n_heads = query_dim // d_head
            gated = GatedSelfAttentionDense(query_dim, key_dim, n_heads, d_head)
            gated.load_state_dict(n_sd, strict=False)
            block_modules.append(gated)
        module_grid.append(block_modules)

    in_dim = sd["position_net.null_positive_feature"].shape[0]
    out_dim = sd["position_net.linears.4.weight"].shape[0]

    class WeightsLoader(torch.nn.Module):
        pass
    w = WeightsLoader()
    w.position_net = PositionNet(in_dim, out_dim)
    w.load_state_dict(sd, strict=False)

    return GligenXL(module_grid, w.position_net, key_dim)


class GLIGENXLLoader:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"gligen_name": (folder_paths.get_filename_list("gligen"),)}}

    RETURN_TYPES = ("GLIGEN",)
    FUNCTION = "load_gligen"
    CATEGORY = "loaders"

    def load_gligen(self, gligen_name):
        path = folder_paths.get_full_path_or_raise("gligen", gligen_name)
        sd = comfy.utils.load_torch_file(path, safe_load=True)
        model = load_gligen_xl(sd)
        if comfy.model_management.should_use_fp16():
            model = model.half()
        load_device = comfy.model_management.get_torch_device()
        offload_device = comfy.model_management.unet_offload_device()
        patcher = comfy.model_patcher.ModelPatcher(model, load_device=load_device, offload_device=offload_device)
        return (patcher,)


class GLIGENXLTextBoxApply:
    """SDXL variant of GLIGENTextBoxApply.

    GLIGEN-XL's position_net expects a 2048-dim phrase embedding: the clip_l
    pooled output (768) concatenated with the clip_g projected pooled output
    (1280). The stock node passes only the single pooled vector ComfyUI's SDXL
    clip returns (clip_g, 1280), so this node encodes both towers and concats.
    """
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"conditioning_to": ("CONDITIONING", ),
                             "clip": ("CLIP", ),
                             "gligen_textbox_model": ("GLIGEN", ),
                             "text": ("STRING", {"multiline": True, "dynamicPrompts": True}),
                             "width": ("INT", {"default": 64, "min": 8, "max": 8192, "step": 8}),
                             "height": ("INT", {"default": 64, "min": 8, "max": 8192, "step": 8}),
                             "x": ("INT", {"default": 0, "min": 0, "max": 8192, "step": 8}),
                             "y": ("INT", {"default": 0, "min": 0, "max": 8192, "step": 8}),
                             "scheduled_percent": ("FLOAT", {"default": 0.3, "min": 0.0, "max": 1.0, "step": 0.05}),
                             }}
    RETURN_TYPES = ("CONDITIONING",)
    FUNCTION = "append"
    CATEGORY = "model/conditioning/gligen"

    def append(self, conditioning_to, clip, gligen_textbox_model, text, width, height, x, y, scheduled_percent=0.3):
        tokens = clip.tokenize(text)
        # Forces the clip model onto its device before the direct tower calls below.
        clip.encode_from_tokens(tokens, return_pooled=True)
        model = clip.cond_stage_model
        if not (hasattr(model, "clip_l") and hasattr(model, "clip_g")):
            raise RuntimeError("GLIGENXLTextBoxApply requires an SDXL dual-tower CLIP (clip_l + clip_g)")
        # clip_l must return the raw pooler output: SDXL checkpoints carry no
        # clip_l text_projection (the projected pooled is uninitialized memory,
        # NaN), and the GLIGEN-XL training pipeline uses the unprojected pooler
        # for this tower. clip_g stays projected, matching its text_embeds.
        model.clip_l.set_clip_options({"projected_pooled": False})
        try:
            _, l_pooled = model.clip_l.encode_token_weights(tokens["l"])
        finally:
            model.clip_l.reset_clip_options()
        _, g_pooled = model.clip_g.encode_token_weights(tokens["g"])
        cond_pooled = torch.cat([l_pooled, g_pooled], dim=-1)

        # Scheduled sampling (GLIGEN paper / diffusers gligen_scheduled_sampling_beta):
        # grounding steers only the first scheduled_percent of steps, then the cond
        # continues ungrounded so the base model refines composition normally.
        # Implemented by splitting each cond into two timestep ranges.
        c = []
        for t in conditioning_to:
            n = [t[0], t[1].copy()]
            position_params = [(cond_pooled, height // 8, width // 8, y // 8, x // 8)]
            prev = []
            if "gligen" in n[1]:
                prev = n[1]['gligen'][2]
            n[1]['gligen'] = ("position", gligen_textbox_model, prev + position_params)
            if scheduled_percent >= 1.0:
                c.append(n)
                continue
            n[1]['start_percent'] = 0.0
            n[1]['end_percent'] = scheduled_percent
            rest = [t[0], t[1].copy()]
            rest[1].pop('gligen', None)
            rest[1]['start_percent'] = scheduled_percent
            rest[1]['end_percent'] = 1.0
            c.append(n)
            c.append(rest)
        return (c, )


NODE_CLASS_MAPPINGS = {
    "GLIGENXLLoader": GLIGENXLLoader,
    "GLIGENXLTextBoxApply": GLIGENXLTextBoxApply,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "GLIGENXLLoader": "GLIGEN-XL Loader (SDXL)",
    "GLIGENXLTextBoxApply": "GLIGEN-XL Text Box Apply (SDXL)",
}
