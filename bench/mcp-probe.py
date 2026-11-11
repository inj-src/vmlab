#!/usr/bin/env python3
"""mcp-probe.py <cmd...>: start a stdio MCP server, initialize, list tools, optionally call one.
   env PROBE_CALL='{"name":"list_windows","arguments":{}}' to call a tool."""
import json, os, subprocess, sys
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
def rpc(i, method, params=None, notify=False):
    m = {"jsonrpc": "2.0", "method": method, **({"params": params} if params is not None else {})}
    if not notify: m["id"] = i
    p.stdin.write(json.dumps(m) + "\n"); p.stdin.flush()
    if notify: return None
    while True:
        line = p.stdout.readline()
        if not line: raise SystemExit("server closed")
        r = json.loads(line)
        if r.get("id") == i: return r
init = rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "1"}})
print("server:", init.get("result", {}).get("serverInfo"), init.get("error"))
rpc(0, "notifications/initialized", {}, notify=True)
tools = rpc(2, "tools/list", {})["result"]["tools"]
print(len(tools), "tools:", ", ".join(t["name"] for t in tools))
if os.environ.get("PROBE_CALL"):
    r = rpc(3, "tools/call", json.loads(os.environ["PROBE_CALL"]))
    for c in r.get("result", {}).get("content", []):
        print(c.get("text", c.get("type"))[:1500])
    if "error" in r: print(r["error"])
p.stdin.close(); p.terminate()
