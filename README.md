# VLAN Wizard Wiki

> Guided walkthroughs for setting up VLANs on supported GL.iNet / OpenWrt routers.

## Getting Started
- Read the [Setup Walkthrough](docs/WALKTHROUGH.md)
- Choose your model below
- Use the install script and follow the model-specific steps

## Model Walkthroughs
1. [GL.iNet GL-BE14000 — Flint 4](wiki-models/GL-BE14000.md)
2. [GL.iNet GL-MT6000 — Flint 2](wiki-models/GL-MT6000.md)
3. [GL.iNet GL-BE6500 — Flint 3e](wiki-models/GL-BE6500.md)
4. [GL.iNet BE3600](wiki-models/BE3600.md)
5. [GL.iNet GL-BE10000 — Slate 7 Pro](wiki-models/GL-BE10000.md)

## Install
```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/zippyy/GL.iNet-VLAN-Wizard/main/install.sh)"
```

## LuCI Plugin
```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/zippyy/GL.iNet-VLAN-Wizard/feature/luci-plugin/install-luci.sh)"
```

## Docs
- [Supported Models](docs/SUPPORTED-MODELS.md)
- [Contributing a New Model](docs/CONTRIBUTING.md)
