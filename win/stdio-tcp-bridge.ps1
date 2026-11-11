# stdio-tcp-bridge.ps1 -Port <n> -Exe <path> [-ArgLine "mcp"]
# Serve a stdio MCP server on 127.0.0.1:<Port> from the interactive desktop session: each TCP
# connection gets its own child process, with the socket piped to its stdin/stdout. The Linux host
# reaches it with `ssh -W 127.0.0.1:<Port>` (vm-mcp-tcp), so GUI tools run where the desktop is
# visible instead of in SSH's invisible Session 0. Started at logon by a scheduled task.
param([int]$Port = 8010, [Parameter(Mandatory)][string]$Exe, [string]$ArgLine = 'mcp')
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System; using System.Diagnostics; using System.IO; using System.Net; using System.Net.Sockets; using System.Threading.Tasks;
public static class StdioTcpBridge {
  public static void Serve(int port, string exe, string args) {
    var listener = new TcpListener(IPAddress.Loopback, port);
    listener.Start();
    while (true) {
      var client = listener.AcceptTcpClient();
      client.NoDelay = true;
      Task.Run(() => Handle(client, exe, args));
    }
  }
  // Flush after every chunk: MCP messages are small, and a buffered pipe would hold them back.
  static async Task Pump(Stream from, Stream to) {
    var buf = new byte[65536]; int n;
    try { while ((n = await from.ReadAsync(buf, 0, buf.Length)) > 0) { await to.WriteAsync(buf, 0, n); await to.FlushAsync(); } }
    catch { }
  }
  static void Handle(TcpClient client, string exe, string args) {
    Process p = null;
    try {
      var psi = new ProcessStartInfo(exe, args) {
        UseShellExecute = false, CreateNoWindow = true,
        RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
      p = Process.Start(psi);
      p.ErrorDataReceived += (s, e) => { };
      p.BeginErrorReadLine();
      var net = client.GetStream();
      Task.WaitAny(Pump(net, p.StandardInput.BaseStream), Pump(p.StandardOutput.BaseStream, net));
    } catch { }
    finally {
      try { client.Close(); } catch { }
      try { if (p != null && !p.HasExited) p.Kill(); } catch { }
    }
  }
}
'@

[StdioTcpBridge]::Serve($Port, $Exe, $ArgLine)
