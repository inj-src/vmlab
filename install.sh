#!/usr/bin/env bash
# install.sh: put the lab's home-folder files in place, as links into this repository, so the
# repository is the one copy. Run it again after adding a file under home/. No root.
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
exit $rc
