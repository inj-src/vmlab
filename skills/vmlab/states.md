# Saved states and the default state

A saved state is a VM's whole disk kept under a name beside the default state: a Windows with a project installed and its database filled, a browser that is logged in. Use one when you would otherwise redo the same setup after every reset.

- **List:** `vm states --plain` (name, size, when saved, a note, which one the VM is on).
- **Use:** `vm start win hq` boots it as saved. Your run's changes are not in the state until it is saved again. Clean up with `vm stop win` and `vm reset win --discard`.
- **Make:** set the VM up, `vm stop win`, then `vm save win hq "HQ shell installed, database seeded"`. Name it after the project and say in the note what is in it; `--replace` writes over a state of yours. Tell the user about each state you made.
- **Running:** `vm save win hq --live` saves a VM that runs, and it runs on. The disk only: the state boots fresh, as after a power cut (Windows' writes wait under a second; the Mac's disk waits about 10 s). The save button in each VM window's title bar does this over the state the VM is on (`vm save <vm> --button`; on the default state it asks for a name): it is the user's.
- **Size:** a `win` state is as large as what its run wrote (0.4 GB after ten minutes, 1 to 2 GB after a long session): save right after the setup. `mac` states live inside the Mac's disk file.
- **Remove:** `vm clear win hq`, for states you made.
- **Defender:** a run started with `vm start win [state] --defender` keeps Defender on in what it saves, so save it under a new name: `vm save` writes it over a state without Defender only when given `--defender` too. `vm states` says "Defender on" beside such states.
- **USB passthrough (`win`):** a state whose `/vmlab/images/states/win/NAME.usb` lists devices (one `vendor:product` in hex a line, `#` comments) gets each of them whenever it is plugged into this laptop; the laptop has it back when the VM stops. `vm save` and `vm start` carry the list with the state, and `vm states` says "USB passthrough". `ruet` (the user's, for STM32 work in Keil and Arduino) lists every ST-LINK probe, the STM32 DFU bootloader, Arduino boards and the common USB-serial chips. A device not covered by the host's udev rules (ST, Arduino, CH340/CH9102, FT232R, CP2102) also needs a rule (README, "The host").
- **Not yours:** `pebble` on each VM is the user's own setup. Start it; never save over or delete it. When `vm reset` refuses because the VM ran on a state and was not saved since, pass `--discard` only for a run you started; otherwise ask the user.

## The default state

`vm reset` returns to it; `vm commit <name>` replaces it for every agent, so run it only when the user asks for a permanent change. On `win` the saved states stand on the default state: `vm commit win --keep-states` keeps each as it was (a state does not get the commit's change; make the change inside it too and save it again), `--drop-states` deletes them.
