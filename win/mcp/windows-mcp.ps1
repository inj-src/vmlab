# Windows-MCP streamable-http server on 127.0.0.1:8000 (desktop session). Host: vm tunnel win 8000
$env:ANONYMIZED_TELEMETRY = 'false'
$env:WINDOWS_MCP_AUTH_KEY = '47230941913d346aa8c94759b4c1f3c1d9a05f780d55b3cd'
uvx --python 3.14 windows-mcp serve --transport streamable-http --host 127.0.0.1 --port 8000 *> C:\vmlab\mcp\windows-mcp.log
