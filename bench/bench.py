#!/usr/bin/env python3
"""vmlab computer-use MCP benchmark.

Runs the same GUI tasks against one MCP server at a time with headless `claude -p`.
The agent gets only that MCP's tools (no Bash/Read/etc.), and every task is verified
by checking real state inside the VM over SSH, never by trusting the agent's reply.

  bench.py win windows-mcp [--tasks notepad,calc] [--reps 1] [--model sonnet] [--tag gpu]
  bench.py report

The MCP must already be installed and reachable (see mcps/<os>/<name>.json).
Results append to results.jsonl next to this file.
"""
import argparse, json, os, re, shlex, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results.jsonl"
KEY = Path.home() / ".ssh/vmlab_ed25519"
KNOWN = Path.home() / ".cache/vmlab/known_hosts"
VMNAME = {"win": "win", "mac": "mac"}


def vm_addr(os_):
    """The VM's SSH address and port (`vm ip`, `vm port`)."""
    out = lambda what: subprocess.run(["vm", what, VMNAME[os_]], capture_output=True, text=True, check=True).stdout.strip()
    return out("ip"), out("port")


def ssh(os_, cmd, timeout=180):
    """Run a command in the VM (win: Windows PowerShell 5.1, mac: zsh). Returns (rc, stdout)."""
    ip, port = vm_addr(os_)
    args = ["ssh", "-i", str(KEY), "-o", f"UserKnownHostsFile={KNOWN}", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8", "-o", "LogLevel=ERROR", "-p", port]
    if os_ == "win":
        args += ["-o", "SetEnv=VMLAB_SHELL=pwsh"]  # PowerShell, not the default Git Bash
    args.append(f"dev@{ip}")
    if os_ == "win":
        # Always go through an explicit powershell.exe so the DefaultShell setting doesn't matter.
        import base64
        enc = base64.b64encode(("$ProgressPreference='SilentlyContinue';" + cmd).encode("utf-16-le")).decode()
        args.append(f"powershell -NoProfile -NonInteractive -EncodedCommand {enc}")
    else:
        args.append(cmd)
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def desktop(os_, cmd, wait=True, timeout=120):
    """Run a command in the logged-on user's GUI session (Windows needs this; macOS ssh is fine for `open`)."""
    if os_ == "win":
        flag = "" if wait else "-NoWait"
        c = cmd.replace("'", "''")
        return ssh(os_, f"& C:\\vmlab\\run-interactive.ps1 -Command '{c}' {flag} -TimeoutSec {timeout}", timeout + 30)
    return ssh(os_, cmd, timeout)


# ---------------------------------------------------------------- tasks
# Each task: setup (shell in VM), prompt (to the agent), verify(answer) -> (ok, detail), cleanup.
W_BENCH = r"C:\bench"
W_APP = r"C:\vmlab\bench-app"


def win_tasks():
    def file_text(path):
        rc, out = ssh("win", f"if (Test-Path '{path}') {{ (Get-Content -Raw '{path}').Trim() }} else {{ '<<missing>>' }}")
        return out

    def start_form():
        ssh("win", f"Remove-Item -Recurse -Force {W_BENCH}\\electron-result.json,{W_BENCH}\\exports -EA SilentlyContinue; "
                   f"New-Item -ItemType Directory -Force {W_BENCH}\\exports | Out-Null")
        desktop("win", f"& {W_APP}\\start.ps1 -Dir {W_BENCH}", wait=True, timeout=60)
        time.sleep(8)

    def kill(*names):
        return lambda: ssh("win", "Stop-Process -Force -Name " + ",".join(names) + " -EA SilentlyContinue")

    def v_notepad(_ans):
        t = file_text(f"{W_BENCH}\\note.txt")
        return t == "vmlab benchmark 42", t[:80]

    def v_calc(ans):
        rc, out = desktop("win", "& C:\\vmlab\\calc-read.ps1")
        shown = "7,006,652" in out or "7006652" in out
        said = "7006652" in ans.replace(",", "")
        return shown and said, f"display={out[-60:]!r}"

    def v_form(_ans):
        t = file_text(f"{W_BENCH}\\electron-result.json")
        try:
            d = json.loads(t)
        except Exception:
            return False, t[:80]
        ok = d.get("name") == "Ada Lovelace" and d.get("color") == "Blue" and d.get("agree") is True
        return ok, json.dumps({k: d.get(k) for k in ("name", "color", "agree")})

    def v_export(_ans):
        t = file_text(f"{W_BENCH}\\exports\\q3-report.txt")
        return t == "bench export ok", t[:80]

    def v_folder(_ans):
        rc, out = ssh("win", f"Test-Path -PathType Container '{W_BENCH}\\from-explorer'")
        return out.strip() == "True", out

    def v_build(ans):
        rc, out = ssh("win", "$k=Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'; \"$($k.CurrentBuild).$($k.UBR)\"")
        return out.strip() in ans, f"real={out.strip()}"

    return {
        "notepad": dict(
            setup=lambda: ssh("win", f"New-Item -ItemType Directory -Force {W_BENCH} | Out-Null; Remove-Item -Force {W_BENCH}\\note.txt -EA SilentlyContinue"),
            prompt=r"Open Notepad, type exactly `vmlab benchmark 42` (nothing else) and save it as C:\bench\note.txt. Then close Notepad.",
            verify=v_notepad, cleanup=kill("notepad")),
        "calc": dict(
            setup=kill("CalculatorApp"),
            prompt="Open the Windows Calculator app and use it to compute 1234 × 5678. Leave Calculator open with the result showing, and reply with the number it displays.",
            verify=v_calc, cleanup=kill("CalculatorApp")),
        "form": dict(
            setup=start_form,
            prompt="A desktop app window titled 'Bench Form' is open. In it, enter the full name 'Ada Lovelace', choose 'Blue' as the favourite colour, tick 'I agree to the terms', and click Submit. Check the status text says 'Saved'.",
            verify=v_form, cleanup=kill("electron")),
        "export": dict(
            setup=start_form,
            prompt=r"A desktop app window titled 'Bench Form' is open. Click its 'Export report…' button and, in the Save dialog that appears, save the file as C:\bench\exports\q3-report.txt (the folder already exists). Check the app's status text confirms the export.",
            verify=v_export, cleanup=kill("electron")),
        "folder": dict(
            setup=lambda: ssh("win", f"Remove-Item -Recurse -Force '{W_BENCH}\\from-explorer' -EA SilentlyContinue; New-Item -ItemType Directory -Force {W_BENCH} | Out-Null"),
            prompt=r"Using File Explorer, create a new folder named 'from-explorer' inside C:\bench. Close File Explorer when done.",
            # Killing explorer.exe would take the taskbar down; close its windows instead.
            verify=v_folder, cleanup=lambda: desktop("win", "(New-Object -ComObject Shell.Application).Windows() | % { $_.Quit() }")),
        # Heavy real-world Electron app: huge accessibility tree, Monaco editor, command palette.
        "vscode": dict(
            setup=lambda: (kill("Code")(), ssh("win", f"New-Item -ItemType Directory -Force {W_BENCH} | Out-Null; Remove-Item -Force {W_BENCH}\\hello.js -EA SilentlyContinue")),
            prompt=r"Open Visual Studio Code, create a new file containing exactly one line: console.log('vmlab') and save it as C:\bench\hello.js. Then close VS Code.",
            verify=lambda _a: (lambda t: (t == "console.log('vmlab')", t[:80]))(file_text(f"{W_BENCH}\\hello.js")),
            cleanup=kill("Code")),
        "build": dict(
            setup=kill("SystemSettings"),
            prompt="Open Windows Settings, go to System > About, and reply with the exact 'OS build' value shown there (for example 12345.6789).",
            verify=v_build, cleanup=kill("SystemSettings")),
    }


M_BENCH = "/Users/dev/bench"
M_APP = "/Users/dev/vmlab/bench-app"


def mac_tasks():
    def file_text(path):
        rc, out = ssh("mac", f"cat '{path}' 2>/dev/null || echo '<<missing>>'")
        return out.strip()

    # Plain signals only: an AppleEvent (osascript) sent over SSH raises a TCC Automation prompt
    # for sshd-keygen-wrapper on the desktop, in the middle of the agent's run.
    def quit_app(*names):
        return lambda: ssh("mac", "; ".join(f"pkill -x '{n}'" for n in names) + "; sleep 1; true")

    def start_form():
        ssh("mac", f"pkill -f 'Electron.app/Contents/MacOS/Electron {M_APP}'; rm -rf {M_BENCH}/electron-result.json {M_BENCH}/exports; "
                   f"mkdir -p {M_BENCH}/exports; open -n {M_APP}/node_modules/electron/dist/Electron.app --env BENCH_DIR={M_BENCH} --args {M_APP}")
        time.sleep(8)

    def stop_form():
        ssh("mac", f"pkill -f 'Electron.app/Contents/MacOS/Electron {M_APP}'; true")

    def v_textedit(_a):
        t = file_text(f"{M_BENCH}/note.txt")
        return t == "vmlab benchmark 42", t[:80]

    def v_calc(ans):
        rc, out = ssh("mac", "pgrep -x Calculator >/dev/null && echo running || echo gone")
        return "7006652" in ans.replace(",", "") and out == "running", out

    def v_form(_a):
        t = file_text(f"{M_BENCH}/electron-result.json")
        try:
            d = json.loads(t)
        except Exception:
            return False, t[:80]
        return d.get("name") == "Ada Lovelace" and d.get("color") == "Blue" and d.get("agree") is True, \
            json.dumps({k: d.get(k) for k in ("name", "color", "agree")})

    def v_export(_a):
        t = file_text(f"{M_BENCH}/exports/q3-report.txt")
        return t == "bench export ok", t[:80]

    def v_folder(_a):
        rc, out = ssh("mac", f"test -d {M_BENCH}/from-finder && echo yes || echo no")
        return out == "yes", out

    def v_version(ans):
        rc, out = ssh("mac", "sw_vers -productVersion")
        return out.strip() in ans, f"real={out.strip()}"

    def v_vscode(_a):
        t = file_text(f"{M_BENCH}/hello.js")
        return t == "console.log('vmlab')", t[:80]

    prep = lambda *rm: (lambda: ssh("mac", f"mkdir -p {M_BENCH}; rm -rf " + " ".join(f"{M_BENCH}/{r}" for r in rm)))
    return {
        "textedit": dict(
            setup=lambda: (quit_app("TextEdit")(), prep("note.txt")()),
            prompt="Open TextEdit and create a new plain-text document (Format > Make Plain Text) containing exactly `vmlab benchmark 42` (nothing else). Save it as note.txt in the folder /Users/dev/bench. Then quit TextEdit.",
            verify=v_textedit, cleanup=quit_app("TextEdit")),
        "calc": dict(
            setup=quit_app("Calculator"),
            prompt="Open the Calculator app and use it to compute 1234 × 5678. Leave Calculator open with the result showing, and reply with the number it displays.",
            verify=v_calc, cleanup=quit_app("Calculator")),
        "form": dict(
            setup=start_form,
            prompt="A desktop app window titled 'Bench Form' is open. In it, enter the full name 'Ada Lovelace', choose 'Blue' as the favourite colour, tick 'I agree to the terms', and click Submit. Check the status text says 'Saved'.",
            verify=v_form, cleanup=stop_form),
        "export": dict(
            setup=start_form,
            prompt="A desktop app window titled 'Bench Form' is open. Click its 'Export report…' button and, in the Save dialog that appears, save the file as q3-report.txt in the folder /Users/dev/bench/exports (it already exists). Check the app's status text confirms the export.",
            verify=v_export, cleanup=stop_form),
        "folder": dict(
            setup=prep("from-finder"),
            prompt="Using Finder, create a new folder named 'from-finder' inside the folder /Users/dev/bench. Close the Finder window when done.",
            verify=v_folder, cleanup=lambda: ssh("mac", "killall Finder; true")),  # relaunches with no windows
        "vscode": dict(
            setup=lambda: (quit_app("Code")(), prep("hello.js")()),
            prompt="Open Visual Studio Code, create a new file containing exactly one line: console.log('vmlab') and save it as hello.js in the folder /Users/dev/bench. Then quit VS Code.",
            verify=v_vscode, cleanup=quit_app("Code")),
        "version": dict(
            setup=quit_app("System Settings"),
            prompt="Open 'About This Mac' (Apple menu) and reply with the exact macOS version number shown (for example 15.1.2).",
            verify=v_version, cleanup=quit_app("System Settings", "SystemUIServer")),
    }


TASKS = {"win": win_tasks, "mac": mac_tasks}


# ---------------------------------------------------------------- runner
SYSTEM = ("You are operating a remote {osname} desktop only through the provided computer-use tools. "
          "You have no shell access to that machine. Complete the task through the GUI, then reply briefly.")


def run_claude(cfg_path, deny, prompt, model, osname, max_turns):
    cmd = ["claude", "-p", prompt, "--model", model, "--output-format", "json",
           "--mcp-config", str(cfg_path), "--strict-mcp-config", "--tools", "",
           "--allowedTools", "mcp__cu", "--max-turns", str(max_turns),
           "--no-session-persistence", "--append-system-prompt", SYSTEM.format(osname=osname)]
    if deny:
        cmd += ["--disallowedTools", *deny]
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=900, cwd=HERE)
    dt = time.time() - t0
    try:
        j = json.loads(p.stdout)
    except Exception:
        j = {"result": (p.stdout + p.stderr)[-500:], "is_error": True}
    return dt, j


def bench(os_, mcp, task_names, reps, model, max_turns, tag=""):
    spec = json.loads((HERE / "mcps" / os_ / f"{mcp}.json").read_text())
    cfg = HERE / "mcps" / os_ / f".{mcp}.mcp.json"
    cfg.write_text(json.dumps({"mcpServers": {"cu": spec["server"]}}))
    tasks = TASKS[os_]()
    for name in task_names or list(tasks):
        t = tasks[name]
        for rep in range(reps):
            if spec.get("ready"):  # untimed: make sure the MCP's host process is up before the clock starts
                ssh(os_, spec["ready"], timeout=150)
            t["setup"]()
            dt, j = run_claude(cfg, spec.get("deny", []), t["prompt"], model, {"win": "Windows 11", "mac": "macOS"}[os_], max_turns)
            ans = str(j.get("result", ""))
            try:
                ok, detail = t["verify"](ans)
            except Exception as e:
                ok, detail = False, f"verify error {e}"
            t["cleanup"]()
            row = dict(os=os_, mcp=mcp, task=name, rep=rep, model=model, ok=ok, secs=round(dt, 1),
                       turns=j.get("num_turns"), cost=j.get("total_cost_usd"), detail=detail,
                       answer=ans[-200:], error=j.get("is_error"), ts=time.strftime("%F %T"))
            if tag:
                row["tag"] = tag
            with RESULTS.open("a") as f:
                f.write(json.dumps(row) + "\n")
            print(f"{mcp:14} {name:8} {'PASS' if ok else 'FAIL'} {dt:6.1f}s turns={row['turns']} ${row['cost'] or 0:.3f}  {detail}", flush=True)


def report():
    rows = [json.loads(l) for l in RESULTS.read_text().splitlines() if l.strip()]
    agg = {}
    for r in rows:
        a = agg.setdefault((r["os"], r["mcp"], r["model"], r.get("tag", "")), dict(n=0, ok=0, secs=0, turns=0, cost=0))
        a["n"] += 1; a["ok"] += r["ok"]; a["secs"] += r["secs"]; a["turns"] += r["turns"] or 0; a["cost"] += r["cost"] or 0
    print(f"{'os':4} {'mcp':16} {'model':8} {'pass':>7} {'avg s':>7} {'avg turns':>9} {'avg $':>7}  tag")
    for (o, m, mod, tag), a in sorted(agg.items(), key=lambda kv: (kv[0][0], -kv[1]["ok"] / kv[1]["n"], kv[1]["secs"])):
        n = a["n"]
        print(f"{o:4} {m:16} {mod:8} {a['ok']:>3}/{n:<3} {a['secs']/n:7.1f} {a['turns']/n:9.1f} {a['cost']/n:7.3f}  {tag}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("os", choices=["win", "mac", "report"])
    ap.add_argument("mcp", nargs="?")
    ap.add_argument("--tasks", default="")
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--max-turns", type=int, default=60)
    ap.add_argument("--tag", default="", help="kept with each result; the report groups by it (e.g. gpu)")
    a = ap.parse_args()
    if a.os == "report":
        report()
    else:
        bench(a.os, a.mcp, [t for t in a.tasks.split(",") if t], a.reps, a.model, a.max_turns, a.tag)
