# Aksho Content Check: the Picturize image check. Every finished Picturize
# image is scored with the WD v3 ViT tagger (SmilingWolf/wd-vit-tagger-v3) and
# withheld when its `loli` score reaches the line the app sends as block_at.
#
# A withheld image never reaches SaveImage. The node hands SaveImage ComfyUI's
# own ExecutionBlocker, which stops it silently: nothing is written to disk,
# nothing is returned to the client, and on the cloud worker nothing goes into
# the job output. The node reports a verdict only ("passed" or "withheld") and
# never the score, and it prints nothing, so no trace of a withheld image is
# kept anywhere.
#
# The image preparation is the calibration scorer's (tagger-check.py,
# 2026-10-07) step for step, so block_at means here what it meant there: the
# pixels SaveImage would write, a white matte, padded to a square, bicubic to
# the model's side, BGR, float 0-255, scored on CPU onnxruntime. Change any of
# it and the calibration no longer holds.
#
# The tagger lives in this extension's own model/ folder, not under
# ComfyUI/models/. The Cloud GPU worker treats every manifest file under
# models/ as something to copy onto the rig's storage, so a tagger there would
# show Core incomplete on every rig; the worker image carries its own copy here.

import csv
import os
import threading

import numpy as np
import onnxruntime as ort
from PIL import Image

from comfy_execution.graph_utils import ExecutionBlocker

MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model")
TAG = "loli"

_session = None
_lock = threading.Lock()


def _load():
    """The tagger, its input name, side and the index of TAG, loaded once."""
    global _session
    with _lock:
        if _session is None:
            model = os.path.join(MODEL_DIR, "model.onnx")
            tags = os.path.join(MODEL_DIR, "selected_tags.csv")
            if not (os.path.isfile(model) and os.path.isfile(tags)):
                raise RuntimeError(
                    "Aksho Content Check: the tagger model is missing from the extension's model folder. Update Aksho ComfyUI."
                )
            with open(tags, encoding="utf-8") as f:
                names = [row["name"] for row in csv.DictReader(f)]
            opts = ort.SessionOptions()
            opts.intra_op_num_threads = max(1, (os.cpu_count() or 4) - 2)
            session = ort.InferenceSession(model, opts, providers=["CPUExecutionProvider"])
            inp = session.get_inputs()[0]
            side = inp.shape[1] if isinstance(inp.shape[1], int) else 448
            _session = (session, inp.name, side, names.index(TAG))
        return _session


def _prepare(pixels, side):
    img = Image.fromarray(pixels).convert("RGBA")
    canvas = Image.new("RGBA", img.size, (255, 255, 255, 255))
    canvas.alpha_composite(img)
    img = canvas.convert("RGB")
    longest = max(img.size)
    square = Image.new("RGB", (longest, longest), (255, 255, 255))
    square.paste(img, ((longest - img.size[0]) // 2, (longest - img.size[1]) // 2))
    if longest != side:
        square = square.resize((side, side), Image.BICUBIC)
    return np.asarray(square, dtype=np.float32)[:, :, ::-1]


class AkshoContentCheck:
    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images": ("IMAGE",),
                "block_at": ("FLOAT", {"min": 0.0, "max": 1.0, "step": 0.001}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "check"
    CATEGORY = "Aksho"

    def check(self, images, block_at):
        session, input_name, side, index = _load()
        withheld = False
        for image in images:
            # The exact bytes SaveImage would write.
            pixels = np.clip(255.0 * image.cpu().numpy(), 0, 255).astype(np.uint8)
            batch = _prepare(pixels, side)[None, ...]
            score = float(session.run(None, {input_name: batch})[0][0][index])
            if score >= block_at:
                withheld = True
                break
        if withheld:
            # A batch is withheld whole: one image of it failing is enough.
            return {"ui": {"content_check": ["withheld"]}, "result": (ExecutionBlocker(None),)}
        return {"ui": {"content_check": ["passed"]}, "result": (images,)}


NODE_CLASS_MAPPINGS = {"AkshoContentCheck": AkshoContentCheck}
NODE_DISPLAY_NAME_MAPPINGS = {"AkshoContentCheck": "Aksho Content Check"}
