# Aksho Content Check: the Picturize image check. Every finished Picturize
# image is scored with the WD v3 ViT tagger (SmilingWolf/wd-vit-tagger-v3) and
# withheld when its `loli` score reaches the line the app sends as block_at,
# or when its `child` or `aged_down` score reaches the second line,
# child_block_at (0.2, CEO 2026-11-19).
#
# A withheld image never reaches SaveImage. The node hands SaveImage ComfyUI's
# own ExecutionBlocker, which stops it silently: nothing is written to disk,
# nothing is returned to the client, and on the cloud worker nothing goes into
# the job output. The node reports a verdict only ("passed" or "withheld") and
# never the score, and it prints nothing, so no trace of a withheld image is
# kept anywhere.
#
# Dev-only metadata log, off unless the machine sets AKSHO_CONTENT_CHECK_LOG
# (a file path, or "1" for ComfyUI/user/aksho-content-check.jsonl). Shipped
# installs and the cloud worker never set it. When on, every scored image adds
# one JSON line: time, prompt id, node id, verdict, the loli score and the line
# it was held to, the age-related tag scores, the top tags, size, seeds and the
# prompt text. Never the image. It exists to tell false positives from real
# catches; the check itself is unchanged by it.
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
import datetime
import json
import os
import threading

import numpy as np
import onnxruntime as ort
from PIL import Image

from comfy_execution.graph_utils import ExecutionBlocker

MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model")
TAG = "loli"
# The second line's tags, held to child_block_at: either one reaching it withholds.
CHILD_TAGS = ("child", "aged_down")
# The app's PICTURIZE_CHECK_CHILD_BLOCK_AT; a graph can ask for stricter, never looser.
CHILD_BLOCK_AT = 0.2

_session = None
_child_index = None
_lock = threading.Lock()


def _load():
    """The tagger, its input name, side and the index of TAG, loaded once."""
    global _session, _child_index
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
            _child_index = tuple(names.index(t) for t in CHILD_TAGS)
            _session = (session, inp.name, side, names.index(TAG), names)
        return _session


# --- dev-only metadata log (see the header); nothing below runs unless AKSHO_CONTENT_CHECK_LOG is set
LOG_ENV = "AKSHO_CONTENT_CHECK_LOG"
LOG_DEFAULT_NAME = "aksho-content-check.jsonl"
# tags that bear on how old a body reads, logged whatever their score
LOG_WATCH = ("loli", "child", "female_child", "toddler", "aged_down", "petite", "flat_chest", "small_breasts",
             "medium_breasts", "large_breasts", "mature_female", "1girl", "1boy", "solo", "close-up", "from_behind", "pov")
_log_lock = threading.Lock()


def _log_path():
    value = os.environ.get(LOG_ENV, "").strip()
    if not value:
        return None
    if value.lower() in ("1", "true", "yes", "on"):
        import folder_paths
        return os.path.join(folder_paths.get_user_directory(), LOG_DEFAULT_NAME)
    return value


def _graph_facts(prompt):
    """Seeds and prompt texts from the graph being run (the API-format prompt)."""
    seeds, texts = [], []
    for node in (prompt or {}).values():
        if not isinstance(node, dict):
            continue
        inputs = node.get("inputs", {})
        if "seed" in inputs and isinstance(inputs["seed"], (int, float)):
            seeds.append(int(inputs["seed"]))
        if node.get("class_type") == "CLIPTextEncode" and isinstance(inputs.get("text"), str):
            texts.append(inputs["text"][:6000])
    return seeds, texts


def _log(path, record):
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with _log_lock, open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as error:  # the log must never change the check's outcome
        print(f"[AKSHO CONTENT CHECK] Dev log write failed: {error}")


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
            },
            # Optional, so a graph from an older app still gets the node's own line.
            "optional": {"child_block_at": ("FLOAT", {"default": CHILD_BLOCK_AT, "min": 0.0, "max": 1.0, "step": 0.001})},
            # graph and node id, read only by the dev-only log
            "hidden": {"prompt": "PROMPT", "unique_id": "UNIQUE_ID"},
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "check"
    CATEGORY = "Aksho"

    def check(self, images, block_at, child_block_at=CHILD_BLOCK_AT, prompt=None, unique_id=None):
        # The line is pinned here, not trusted from the graph: whoever edits a
        # graph can ask for a stricter line, never a looser one. 0.5 is the app's
        # PICTURIZE_CHECK_BLOCK_AT. Written so a NaN lands on the pin too
        # (min() would hand NaN back, and no score is >= NaN).
        block_at = float(block_at) if float(block_at) <= 0.5 else 0.5
        child_block_at = float(child_block_at) if float(child_block_at) <= CHILD_BLOCK_AT else CHILD_BLOCK_AT
        session, input_name, side, index, names = _load()
        log_path = _log_path()
        withheld = False
        for position, image in enumerate(images):
            # The exact bytes SaveImage would write.
            pixels = np.clip(255.0 * image.cpu().numpy(), 0, 255).astype(np.uint8)
            batch = _prepare(pixels, side)[None, ...]
            probs = session.run(None, {input_name: batch})[0][0]
            score = float(probs[index])
            child = max(float(probs[i]) for i in _child_index)
            reason = "loli" if score >= block_at else ("child" if child >= child_block_at else None)
            if log_path:
                seeds, texts = _graph_facts(prompt)
                try:
                    from server import PromptServer
                    prompt_id = getattr(PromptServer.instance, "last_prompt_id", None)
                except Exception:
                    prompt_id = None
                top = sorted(((names[i], float(p)) for i, p in enumerate(probs) if p >= 0.35), key=lambda item: -item[1])[:30]
                _log(log_path, {
                    "time": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                    "prompt_id": prompt_id, "node": unique_id, "image": position,
                    "verdict": "withheld" if reason else "passed", "reason": reason,
                    "score": round(score, 4), "block_at": block_at, "child_block_at": child_block_at,
                    "width": int(pixels.shape[1]), "height": int(pixels.shape[0]),
                    "watch": {t: round(float(probs[names.index(t)]), 4) for t in LOG_WATCH if t in names},
                    "top": [[n, round(p, 3)] for n, p in top],
                    "seeds": seeds, "texts": texts,
                })
            if reason:
                withheld = True
                break
        if withheld:
            # A batch is withheld whole: one image of it failing is enough.
            return {"ui": {"content_check": ["withheld"]}, "result": (ExecutionBlocker(None),)}
        return {"ui": {"content_check": ["passed"]}, "result": (images,)}


NODE_CLASS_MAPPINGS = {"AkshoContentCheck": AkshoContentCheck}
NODE_DISPLAY_NAME_MAPPINGS = {"AkshoContentCheck": "Aksho Content Check"}
