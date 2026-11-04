# Aksho Comfy

One-click local image generation for [AkshoAI's Atelier](https://akshoai.com/atelier). Download one file, double-click it, pick the kind of pictures you want, and get a ready-to-use ComfyUI install with the checkpoint, the model support it runs on and the Atelier tools made for it.

## Requirements

- Windows 10 or 11, 64-bit
- NVIDIA GPU (8 GB VRAM or more recommended)
- About 18 GB of free disk space for a starter set (Core, 2.5D, Illustrious support, 3D Poser and Inpaint), up to about 70 GB with every pack ticked
- An internet connection for the initial download

## Install

1. Download [`install.bat`](https://raw.githubusercontent.com/aksho-technologies/aksho-comfy/main/install.bat) (Right click, Save link as).
2. Double-click it. Pick at least one base checkpoint, or **None** to bring your own, tick the tools you want, choose an install folder (default `C:\AkshoComfy`), and hit Install.
3. Wait for the downloads to finish. ComfyUI starts automatically and your browser opens Atelier: choose the **Local** provider and connect.

Each base checkpoint ticks the model support it runs on, and on a first install the tools made for it. Ticking a tool ticks the model support it needs too. Untick anything you will not use and the installer skips those downloads entirely; run **`Update Aksho ComfyUI.bat`** later to add a pack back. Removing a tick never deletes files you already have, it only stops keeping them up to date.

From then on, start everything with **`Run Aksho ComfyUI.bat`** in your install folder.

> **Windows SmartScreen note:** the first run may show "Windows protected your PC". Click **More info** then **Run anyway**. The installer is a small, readable script; you can open it in Notepad to see everything it does.

## What's in the box

Each row is one tick box in the installer.

| Pack | Download | What it brings |
|---|---|---|
| **Core** | 2.8 GB | ComfyUI portable, the Aksho nodes and the Aksho relay agent for optional remote play. Always installed |
| **Base checkpoint** (pick one or more, or None) | | |
| Anime | | An Anima checkpoint. Coming soon |
| 2.5D | 6.5 GB | The Dreamhex v5 checkpoint by Vetehine, an Illustrious model |
| Realistic | | A Krea2 checkpoint. Coming soon |
| All in One | 9.5 GB | MOSS Image, one model for any style (realistic, anime, painterly); for 24 GB cards |
| All in One Lite | 5.0 GB | The same model made smaller to run on 8 GB cards |
| **Model support** | | |
| Illustrious support | 3.8 GB | Image reference so a character's identity carries across pictures, face and hand cleanup, and the 4x-AnimeSharp upscaler |
| MOSS support | 18.2 GB | Text encoder and VAE for All in One |
| MOSS support Lite | 7.1 GB | Text encoder and VAE for All in One Lite |
| Anima support | 1.4 GB | Text encoder and VAE for Anima checkpoints |
| Z-Image support | 5.6 GB | Text encoder and VAE for Z-Image checkpoints |
| Krea2 support | 5.1 GB | Text encoder and VAE for Krea2 checkpoints |
| **Tools** | | |
| 3D Poser | 4.7 GB | OpenPose and Depth ControlNets. Works with Illustrious |
| Inpaint | 0.3 GB | LaMa erase on any model, and regenerate or fill on Illustrious |

The model support packs provide the plumbing each kind of checkpoint needs. Pick **None** and tick the support for the checkpoints you bring yourself.

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
