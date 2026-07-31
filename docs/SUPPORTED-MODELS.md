# Supported Models

Last updated: 2026-07-31

| Model | Codename | OpenWrt Target | Mode | Notes |
|---|---|---|---|---|
| GL.iNet GL-BE14000 | Flint 4 | `mediatek/mt7987` | DSA | Primary development target |
| GL.iNet GL-MT6000 | Flint 2 | `mediatek/mt7986` | swconfig | Verified |
| GL.iNet GL-BE6500 | Flint 3e | `ipq53xx/generic` | DSA | Board reports `Qualcomm IPQ5332/AP-MI01.2` |
| GL.iNet BE3600 | — | `ipq53xx/generic` | DSA | Board reports `Qualcomm IPQ5332/AP-MI04.1-C2` |
| GL.iNet GL-BE10000 | Slate 7 Pro | `mediatek/mt7987` | DSA | Verified |

## How to add a new model
1. Collect SSH access and run model detection commands
2. Add a page under `wiki-models/` with the walkthrough
3. Update this table and `install.sh` model map
