# Setup Walkthrough

This guide walks through setting up VLANs on supported GL.iNet/OpenWrt routers using the VLAN Wizard.

## Prerequisites
- SSH access to the router as root
- `curl` or `wget` on the router
- Basic familiarity with VLAN concepts

## Quick Start
```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/zippyy/GL.iNet-VLAN-Wizard/main/install.sh)"
```

## Model-Specific Guides
See `wiki-models/` for per-model walkthroughs:
- `wiki-models/GL-BE14000.md`
- `wiki-models/GL-BE10000.md`
- `wiki-models/GL-MT6000.md`
- `wiki-models/GL-BE6500.md`
- `wiki-models/BE3600.md`

## What the wizard does
- Creates per-VLAN interfaces on `192.168.<VLAN>.0/24`
- Enables DHCP and isolated firewall zones
- Sets up WAN forwarding
- Optionally creates per-VLAN Wi-Fi SSIDs on all radios
- Validates VLAN IDs, port conflicts, and subnets
- Creates a rollback safety net
