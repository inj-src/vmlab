# Working on vmlab

This repository is the lab behind the `win` and `mac` test VMs. To **use** the VMs, load the `vmlab` skill (`skills/vmlab/`); this file is for changing the lab itself.

- **What to read:** `docs/lab.md` (how the lab is put together, where things live, disk space), `gpu/README.md` before touching a launcher or the GPU stack (every local patch with its cause and test), `vmlab-mcp/README.md` before changing the MCP server.
- **The skill is the agents' interface.** When a change alters what an agent using the VMs must do or know, update `skills/vmlab/` in the same commit. Put there only what such an agent acts on; causes, history and measurements go in `docs/lab.md` or the component's README.
- **Files under `home/`** are linked into the home folder (`~/.local/bin/vm`, `~/.config/vmlab/`, the launchers): edit them here. `./install.sh` makes the links, links the skill and registers vmlab-mcp; run it after adding a file under `home/` or `skills/`.
- **Commits:** one per finished piece, to `main` (or a PR when asked), pushed; never force-push. Scan the diff for secrets first.
- **Root** goes through one GUI prompt: `SUDO_ASKPASS=~/.local/bin/zenity-askpass sudo -A …`. Record every root change under `host/`.
- `vm commit`, deleting anything listed in `docs/lab.md`, posting upstream and root changes need the user's go.
