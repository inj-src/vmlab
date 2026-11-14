#!/usr/bin/env bash
# install.sh: put the lab's home-folder files and its agent skill in place, as links into this
# repository, so the repository is the one copy, and register vmlab-mcp with the agent tools.
# Run it again after adding a file under home/ or skills/. No root.
#
# For each file under home/, $HOME/<same path> becomes a link to it. A file already there with
# other content is left alone and named; move it away, or copy it over the one in home/, and run
# this again.
set -euo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
rc=0
while IFS= read -r -d '' src; do
  rel=${src#"$REPO/home/"}; dest=$HOME/$rel
  if [[ -L $dest && $(readlink -f "$dest") == "$src" ]]; then continue; fi
  if [[ -e $dest || -L $dest ]] && ! cmp -s "$src" "$dest"; then
    echo "install: $dest differs from home/$rel: left alone" >&2; rc=1; continue
  fi
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
  echo "linked ~/$rel"
done < <(find "$REPO/home" -type f -print0 | sort -z)

# `ssh win` and `ssh mac`: ~/.ssh/config includes the lab's host entries. Include must stand
# before any Host line, so it goes first. ssh refuses a config that others may write to.
inc='Include ~/.config/vmlab/ssh_config'
chmod 644 "$REPO/home/.config/vmlab/ssh_config"
if ! grep -qxF "$inc" "$HOME/.ssh/config" 2>/dev/null; then
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  { echo "$inc"; echo; cat "$HOME/.ssh/config" 2>/dev/null || true; } > "$HOME/.ssh/config.vmlab-new"
  chmod 600 "$HOME/.ssh/config.vmlab-new" && mv "$HOME/.ssh/config.vmlab-new" "$HOME/.ssh/config"
  echo "added the lab's hosts to ~/.ssh/config (ssh win, ssh mac)"
fi

# A link into this repository whose file is gone (moved or deleted here) goes too.
for dir in "$HOME/.local/bin" "$HOME/.config/vmlab" "$HOME/.local/share/applications"; do
  [[ -d $dir ]] || continue
  while IFS= read -r -d '' link; do
    [[ $(readlink "$link") == "$REPO"/* ]] || continue
    rm "$link"; echo "removed ${link/#"$HOME"/\~}: its file left the repository"
  done < <(find "$dir" -maxdepth 1 -xtype l -print0)
done

# The agent skill, for Claude Code and Codex where installed.
skill=$REPO/skills/vmlab
for dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  [[ -d $(dirname "$dir") ]] || continue
  dest=$dir/vmlab
  if [[ -L $dest && $(readlink -f "$dest") == "$skill" ]]; then continue; fi
  if [[ -e $dest || -L $dest ]]; then echo "install: $dest exists: left alone" >&2; rc=1; continue; fi
  mkdir -p "$dir" && ln -s "$skill" "$dest" && echo "linked the vmlab skill into ${dir/#"$HOME"/\~}"
done

# vmlab-mcp, the GUI tools, for the same tools. Codex's calls get 180 s: the first one after
# `vm start` can wait 90 s for the desktop.
mcp=$HOME/.local/bin/vmlab-mcp
if command -v claude > /dev/null && ! claude mcp get vmlab > /dev/null 2>&1; then
  claude mcp add -s user vmlab -- "$mcp" && echo "registered vmlab-mcp for Claude Code"
fi
if command -v codex > /dev/null; then
  if ! codex mcp get vmlab > /dev/null 2>&1; then
    codex mcp add vmlab -- "$mcp" && echo "registered vmlab-mcp for Codex"
  fi
  python3 -I - "$HOME/.codex/config.toml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
m = re.search(r'^\[mcp_servers\.vmlab\]\n((?:(?!\[).*\n?)*)', s, re.M)
if m and 'tool_timeout_sec' not in m.group(1):
    open(p, 'w').write(s[:m.end(0) - len(m.group(1))] + 'tool_timeout_sec = 180\n' + s[m.end(0) - len(m.group(1)):])
    print('set tool_timeout_sec = 180 for vmlab-mcp in Codex')
PY
fi
exit $rc
