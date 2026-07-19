# Credits and Licenses

The Aksho Comfy installer scripts in this repository are MIT licensed (see [LICENSE](LICENSE)). The bundle it downloads is composed of third-party projects and models, each under its own license:

| Component | Author / Project | License | Status |
|---|---|---|---|
| ComfyUI | comfyanonymous / Comfy-Org | GPL-3.0 | Clear |
| ComfyUI_IPAdapter_plus | cubiq | GPL-3.0 | Clear |
| ComfyUI-Impact-Pack | ltdrdata | GPL-3.0 | Clear |
| ComfyUI-Impact-Subpack | ltdrdata | GPL-3.0 | Clear |
| ComfyUI-ppm | pamparamm | AGPL-3.0 | Clear |
| Dreamhex v5 checkpoint | Vetehine | Redistributed with the author's permission | Clear |
| ip_adapter_Noobtest_800000 | [kataragi](https://huggingface.co/kataragi/Noob_ipadapter) | CreativeML OpenRAIL-M | Clear (use-based restrictions carry to users) |
| CLIP-ViT-H-14-laion2B-s32B-b79K | LAION / OpenCLIP | MIT | Clear |
| OpenPose ControlNet (Illustrious) | [windsingai](https://huggingface.co/windsingai/Illustrious-XL-openpose-test) | Apache-2.0 | Clear |
| Depth ControlNet | [Eugeoter / noob-sdxl-controlnet-depth](https://huggingface.co/Eugeoter/noob-sdxl-controlnet-depth) (identity confirmed by sha256) | [Fair AI Public License 1.0-SD](https://freedevproject.org/faipl-1.0-sd/) (share-alike; this notice passes the license along) | Clear under FAIPL itself; NoobAI base-model lineage carries an unsettled anti-commercial claim, flagged for legal review |
| face_yolov9c / hand_yolov9c | [Bingsu/adetailer](https://huggingface.co/Bingsu/adetailer), Ultralytics YOLO | Contested (HF card Apache-2.0 vs Ultralytics AGPL-3.0 claim) | Not redistributed by Aksho: the installer downloads these two files directly from the original Bingsu/adetailer repository, the same source the A1111 ADetailer extension and ComfyUI Impact-Subpack use |
| 4x-AnimeSharp | [Kim2091](https://huggingface.co/Kim2091/AnimeSharp) | CC BY-NC-SA 4.0 | PENDING: author permission requested per Kim2091's stated policy (private ask for commercial-entity use) |

The PENDING row must be resolved before the download bucket goes public.
