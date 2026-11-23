# Getting code and files into a VM

## A repository: `vm push <name> <dir> [dest]`

Mirrors the git work tree at `<dir>` (committed, uncommitted and untracked files, not ignored ones) to `C:\cache\src\<repo>` on `win` or `~/cache/src/<repo>` on `mac`. Later pushes send only the changes, and the guest's ignored build output (`target/`, `node_modules/`) stays, so builds after a push are incremental.

- Git repositories only; submodules and Git LFS content are not sent.
- The guest copy is a mirror: changes made there (other than ignored files) are overwritten by the next push.
- The host repository is untouched apart from the ref `refs/vmlab/push/<name>`.

## The build cache: `C:\cache`, `~/cache`

A disk of its own per VM that `vm reset` leaves alone, so a pushed checkout, its build output and cargo's downloads survive a reset.

- 25 GB per VM at most. `vm cache` shows the sizes; `vm cache clear <name>` empties one (VM stopped). Out of room: remove old `target` folders or clear it.
- It is shared by every agent and project: another project's checkout there is not yours to delete.
- What a test must not inherit (an installed app, settings, a database) belongs on the system disk, which reset cleans.

## Large or loose files: `/vmlab/share`

The folder `/vmlab/share` on this machine is `C:\share` on `win` and `~/share` on `mac`, both ways, while the VM runs (on `mac` about 15 s after `vm start` returns).

- **Writing into it, the tool matters.** On `win`, Git Bash `cp` writes 2.9 MB/s (17 s for 50 MB); use `Copy-Item` in `ssh win-pwsh` (89 MB/s), `cmd //c copy` (137) or `scp` from here. On `mac`, `cp` writes about 20 MB/s; use `dd if=<file> of=~/share/<name> bs=1m` or `scp` (about 150). Reading from it is fast with any tool (200–240 MB/s).
- Build on the guest's own disk (`vm push`), not in the share: there every file access is a network round trip.
- It is one folder for both VMs and outlives `vm reset`: remove what you put there.

## Single files

`scp file win:C:/share/`, `scp mac:<file> .`
