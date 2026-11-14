# Saved states and the clean state

A saved state is a VM's whole disk kept under a name beside the clean state: a Windows with a project installed and its database filled, a browser that is logged in. Use one when you would otherwise redo the same setup after every reset.

- **List:** `vm states --plain` (name, size, when saved, a note, which one the VM is on).
- **Use:** `vm start win hq` boots it as saved. Your run's changes are not in the state until it is saved again. Clean up with `vm stop win` and `vm reset win --discard`.
- **Make:** set the VM up, `vm stop win`, then `vm save win hq "HQ shell installed, database seeded"`. Name it after the project and say in the note what is in it; `--replace` writes over a state of yours. Tell the user about each state you made.
- **Size:** a `win` state is as large as what its run wrote (0.4 GB after ten minutes, 1 to 2 GB after a long session): save right after the setup. `mac` states live inside the Mac's disk file.
- **Remove:** `vm clear win hq`, for states you made.
- **Not yours:** `pebble` on each VM is the user's own setup and `defender` on `win` is the lab's. Start them; never save over or delete them. When `vm reset` refuses because the VM ran on a state and was not saved since, pass `--discard` only for a run you started; otherwise ask the user.

## The clean state

`vm reset` returns to it; `vm commit <name>` replaces it for every agent, so run it only when the user asks for a permanent change. On `win` the saved states stand on the clean state: `vm commit win --keep-states` keeps each as it was (a state does not get the commit's change; make the change inside it too and save it again), `--drop-states` deletes them.
