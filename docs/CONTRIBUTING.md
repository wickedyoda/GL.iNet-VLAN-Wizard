# Contributing a New Model

1. SSH into the router and collect:
   - `ubus call system board`
   - `cat /etc/openwrt_release`
   - `cat /etc/board.json`
   - `uci show network`
   - `swconfig dev switch0 show` or DSA bridge-vlan status
2. Create `wiki-models/<MODEL>.md` using the existing model pages as templates
3. Update `docs/SUPPORTED-MODELS.md`
4. Update `install.sh` if the model needs special handling
5. Open a PR against the `docs/wiki-models` branch
