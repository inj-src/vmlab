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

The folder `/vmlab/share` on this machine is `C:\share` on `win` and `~/share` on `mac`, both ways, while the VM runs (on `mac` about 30 s after SSH answers).

- `win` reads about 500 MB/s and writes 260; `mac` reads 155 and writes only 22. For a large file out of `mac`, `scp mac:<file> <dir>` is faster (140 MB/s).
- Build on the guest's own disk (`vm push`), not in the share: there every file access is a network round trip.
- It is one folder for both VMs and outlives `vm reset`: remove what you put there.

## Single files

`scp file win:C:/share/`, `scp mac:<file> .`
