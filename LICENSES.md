# Credits and Licenses

The Aksho Comfy installer scripts in this repository are MIT licensed (see [LICENSE](LICENSE)). The bundle it downloads is composed of third-party projects and models, each under its own license:

| Component | Author / Project | License | Status |
|---|---|---|---|
| ComfyUI | comfyanonymous / Comfy-Org | GPL-3.0 | Clear |
| ComfyUI_IPAdapter_plus | cubiq | GPL-3.0 | Clear |
| ComfyUI-Impact-Pack | ltdrdata | GPL-3.0 | Clear |
| ComfyUI-Impact-Subpack | ltdrdata | GPL-3.0 | Clear |
| RES4LYF | [ClownsharkBatwing](https://github.com/ClownsharkBatwing/RES4LYF) | AGPL-3.0 | Able to use |
| gligen-xl loader node | Aksho | MIT (this repository) | Clear |
| gligen-xl-1024 | [jiuntian](https://huggingface.co/jiuntian/gligen-xl-1024), derived from stabilityai/stable-diffusion-xl-base-1.0; builds on GLIGEN (Li et al., CVPR 2023) and IGLIGEN (Lian et al., 2023) | Apache-2.0 | Clear |
| clip_l / clip_g | OpenAI CLIP ViT-L/14 and LAION CLIP ViT-bigG/14 text towers, the same encoders already inside every SDXL checkpoint | MIT (both upstream) | Clear |
| qwen_3_06b_base, qwen_3_4b_fp8_mixed, qwen3vl_4b_fp8_scaled | Qwen (Alibaba), repackaged for ComfyUI | Apache-2.0 upstream | Provenance of the repackaged files not yet recorded; confirm before the next publish |
| z_image_ae, qwen_image_vae | Z-Image and Qwen-Image autoencoders | Not yet confirmed | Confirm before the next publish |
| moss_image_sft_bf16, moss_image_sft_int8_convrot | MOSS Image SFT by [OpenMOSS](https://github.com/OpenMOSS/MOSS-Image), repackaged by [Comfy-Org](https://huggingface.co/Comfy-Org/MOSS-Image) | Apache-2.0 | Clear |
| qwen3.5_9b_bf16, qwen3.5_9b_w4a8_gptq | Qwen3.5-9B by Qwen (Alibaba), repackaged by [Comfy-Org](https://huggingface.co/Comfy-Org/MOSS-Image) | Apache-2.0 | Clear |
| flux2-vae_small | FLUX.2 small decoder by Black Forest Labs, repackaged by [Comfy-Org](https://huggingface.co/Comfy-Org/MOSS-Image) | Apache-2.0 | Clear |
| Dreamhex v5 checkpoint | Vetehine | Redistributed with the author's permission | Clear |
| ip_adapter_Noobtest_800000 | [kataragi](https://huggingface.co/kataragi/Noob_ipadapter) | CreativeML OpenRAIL-M | Clear (use-based restrictions carry to users) |
| CLIP-ViT-H-14-laion2B-s32B-b79K | LAION / OpenCLIP | MIT | Clear |
| OpenPose ControlNet (Illustrious) | [windsingai](https://huggingface.co/windsingai/Illustrious-XL-openpose-test) | Apache-2.0 | Clear |
| Depth ControlNet | [Eugeoter / noob-sdxl-controlnet-depth](https://huggingface.co/Eugeoter/noob-sdxl-controlnet-depth) (identity confirmed by sha256) | [Fair AI Public License 1.0-SD](https://freedevproject.org/faipl-1.0-sd/) (share-alike; this notice passes the license along) | Clear under FAIPL itself; NoobAI base-model lineage carries an unsettled anti-commercial claim, flagged for legal review |
| face_yolov9c / hand_yolov9c | [Bingsu/adetailer](https://huggingface.co/Bingsu/adetailer), Ultralytics YOLO | Contested (HF card Apache-2.0 vs Ultralytics AGPL-3.0 claim) | Not redistributed by Aksho: the installer downloads these two files directly from the original Bingsu/adetailer repository, the same source the A1111 ADetailer extension and ComfyUI Impact-Subpack use |
| 4x-AnimeSharp | [Kim2091](https://huggingface.co/Kim2091/AnimeSharp) | CC BY-NC-SA 4.0 | Not redistributed by Aksho: the installer downloads this file directly from the author's repository while permission for CDN hosting is requested per Kim2091's stated policy |
| comfyui-inpaint-nodes | [Acly](https://github.com/Acly/comfyui-inpaint-nodes) | GPL-3.0 | Clear |
| big-lama | [Samsung AI / LaMa](https://github.com/advimman/lama), packaged by [Sanster](https://github.com/Sanster/models) | Apache-2.0 | Clear |
| Aksho Content Check node | Aksho | MIT (this repository) | Clear |
| wd-vit-tagger-v3 | [SmilingWolf](https://huggingface.co/SmilingWolf/wd-vit-tagger-v3), revision 7f6b584d0bd3f55c4531f14ba3d4761b2bccdc0f | Apache-2.0 | Clear |
| onnxruntime | Microsoft | MIT | Clear |

CDN hosting of 4x-AnimeSharp activates only after the author's permission arrives.
