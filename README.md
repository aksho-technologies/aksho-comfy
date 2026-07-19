# Aksho Comfy

One-click local image generation for [AkshoAI's Atelier](https://akshoai.com/atelier). Download one file, double-click it, and get a complete, ready-to-use ComfyUI install with everything Atelier needs: the Dreamhex v5 checkpoint, hi-res upscaling, face and hand detailing, image reference, and full 3D Poser support.

## Requirements

- Windows 10 or 11, 64-bit
- NVIDIA GPU (8 GB VRAM or more recommended)
- About 20 GB of free disk space
- An internet connection for the initial download (~16 GB)

## Install

1. Download [`install.bat`](https://raw.githubusercontent.com/aksho-technologies/aksho-comfy/main/install.bat) (Right click, Save link as).
2. Double-click it and pick an install folder (default `C:\AkshoComfy`).
3. Wait for the downloads to finish. ComfyUI starts automatically and your browser opens Atelier: choose the **Local** provider and connect.

From then on, start everything with **`Run Aksho ComfyUI.bat`** in your install folder.

> **Windows SmartScreen note:** the first run may show "Windows protected your PC". Click **More info** then **Run anyway**. The installer is a small, readable script; you can open it in Notepad to see everything it does.

## What's in the box

| Component | Purpose |
|---|---|
| ComfyUI (portable) | The generation engine, preconfigured for Atelier |
| Dreamhex v5 by Vetehine | The bundled image checkpoint |
| 4x-AnimeSharp | Hi-res upscaling |
| face_yolov9c + hand_yolov9c | Automatic face and hand detailing |
| Anime IP-Adapter + CLIP Vision | Image Reference (consistent characters) |
| OpenPose + Depth ControlNets | 3D Poser support |
| IPAdapter Plus, Impact Pack, Impact Subpack, PPM | Required ComfyUI extensions |
| Aksho relay agent | Optional remote play through the Aksho relay |

Want more models? Drop any additional checkpoints, LoRAs, or upscalers into the matching `ComfyUI\models\` folders and they appear in Atelier automatically.

## Updates

`Run Aksho ComfyUI.bat` checks for updates in about two seconds each launch. When a bundle update exists it asks first, downloads only the changed files, then starts as usual. You can also run `Update Aksho ComfyUI.bat` anytime; the same command repairs missing or corrupted files.

## Troubleshooting

- **Atelier says it cannot reach the server:** make sure the Aksho ComfyUI window is open and shows the server running on port 8188, and that Atelier's Local provider address is `127.0.0.1:8188`.
- **Port 8188 already in use:** close other ComfyUI instances, then start again.
- **Download interrupted:** just run the installer or launcher again; downloads resume where they stopped.
- **Uninstall:** close ComfyUI and delete the install folder. Nothing is written elsewhere.

## Credits and licenses

See [LICENSES.md](LICENSES.md) for the projects and model authors that make this bundle possible.
