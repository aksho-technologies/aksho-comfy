# Aksho Comfy

One-click local image generation for [AkshoAI's Atelier](https://akshoai.com/atelier). Download one file, double-click it, and get a complete, ready-to-use ComfyUI install with everything Atelier needs: the Dreamhex v5 checkpoint, hi-res upscaling, face and hand detailing, image reference, and full 3D Poser support.

## Requirements

- Windows 10 or 11, 64-bit
- NVIDIA GPU (8 GB VRAM or more recommended)
- 15 GB of free disk space for the core install, up to 43 GB with every feature ticked
- An internet connection for the initial download

## Install

1. Download [`install.bat`](https://raw.githubusercontent.com/aksho-technologies/aksho-comfy/main/install.bat) (Right click, Save link as).
2. Double-click it. Tick the features you want, choose an install folder (default `C:\AkshoComfy`), and hit Install.
3. Wait for the downloads to finish. ComfyUI starts automatically and your browser opens Atelier: choose the **Local** provider and connect.

Everything is ticked to start with. Untick anything you will not use and the installer skips those downloads entirely; run **`Update Aksho ComfyUI.bat`** later to add a feature back. Removing a tick never deletes files you already have, it only stops keeping them up to date.

From then on, start everything with **`Run Aksho ComfyUI.bat`** in your install folder.

> **Windows SmartScreen note:** the first run may show "Windows protected your PC". Click **More info** then **Run anyway**. The installer is a small, readable script; you can open it in Notepad to see everything it does.

## What's in the box

Each row is one tick box in the installer.

| Feature | Download | What it brings |
|---|---|---|
| Core | 12.6 GB | ComfyUI portable, the Dreamhex v5 checkpoint by Vetehine, image reference so a character's identity carries across generations, and the Aksho relay agent for optional remote play |
| ADetailer | 101 MB | face_yolov9c + hand_yolov9c with Impact Pack, for automatic face and hand cleanup |
| Upscaling | 64 MB | 4x-AnimeSharp |
| 3D Poser | 4.7 GB | OpenPose and Depth ControlNets |
| Inpaint | 1.4 GB | Fooocus inpaint patch, LaMa erase, and the inpaint nodes |
| Multi-Character | 4.9 GB | Regional conditioning and GLIGEN grounding, for several characters in one image |
| Anima support | 1.1 GB | Text encoder for Anima checkpoints |
| Z-Image support | 5.6 GB | Text encoder and VAE for Z-Image checkpoints |
| Krea2 support | 5.1 GB | Text encoder and VAE for Krea2 checkpoints |

The last three provide the plumbing those architectures need; bring your own checkpoint for them.

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
