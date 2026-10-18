# steam-proxy

A small local proxy that gets around ISP blocking of the Steam store (and Steam Community) without a VPN.

Many ISPs block sites by reading the hostname (SNI) in the TLS ClientHello and by tampering with DNS answers. This proxy:

1. **Resolves hostnames through 1.1.1.1 directly**, skipping the ISP's DNS and the Windows hosts file.
2. **Splits the TLS ClientHello into 8-byte TCP segments**, so a filter that inspects a single packet never sees the full hostname.

The traffic itself stays end-to-end encrypted. The proxy only forwards bytes and cannot read or change them.

It needs only Python 3.8+ (standard library, no dependencies) and listens on `127.0.0.1` only, so other machines can't use it.

## Files

| File | Purpose |
| --- | --- |
| `steam_proxy.py` | The proxy: an HTTPS `CONNECT` proxy plus a PAC file served at `/proxy.pac` |
| `open-steam.bat` | Starts the proxy and opens the Steam store in a separate Chrome profile that uses it |
| `browser-profile/` | Created by `open-steam.bat`. It holds your cookies and logins and is git-ignored. Never commit it |

## Usage

### Option 1: system-wide via PAC (recommended)

Only Steam hosts go through the proxy. Everything else, including game downloads from Steam's CDN, connects directly.

1. Start the proxy:
   ```
   python steam_proxy.py          # default port 8881
   python steam_proxy.py 9000     # custom port
   ```
2. Open **Windows Settings → Network & internet → Proxy → Use setup script**, turn it on and set:
   ```
   http://127.0.0.1:8881/proxy.pac
   ```
3. Open the Steam client or `https://store.steampowered.com/` in any browser.

Hosts sent through the proxy: `*.steampowered.com`, `*.steamcommunity.com`, `*.steamstatic.com`, `*.steamusercontent.com`, `steamcdn-a.akamaihd.net`.

### Option 2: one dedicated browser window

Double-click `open-steam.bat`. It starts the proxy minimized and opens Chrome with `--proxy-server=http://127.0.0.1:8881` and its own profile, which leaves your normal browser alone.

## Start automatically at login

Create a shortcut in the Startup folder (`Win+R` → `shell:startup`) with this target:

```
"C:\Path\To\pythonw.exe" -I "C:\Path\To\steam-proxy\steam_proxy.py"
```

`pythonw.exe` runs it without a console window. `-I` (isolated mode) stops Python from importing stray modules from the current directory.

## Troubleshooting

- **Steam store won't load.** Check whether the proxy is running:
  ```powershell
  Get-NetTCPConnection -LocalPort 8881 -State Listen
  ```
  If nothing is listed, start it again (or check that the Startup shortcut still exists).
- **Check the PAC file.** Open `http://127.0.0.1:8881/proxy.pac` in a browser. You should see the `FindProxyForURL` function.
- **Errors.** When run with `python` (not `pythonw`), connection errors print to the console as `error: ...`.
- **Still blocked.** Some ISPs reassemble TCP streams or block by IP address. Splitting the ClientHello won't help against that, and you'll need a VPN.

## Limitations

- HTTPS `CONNECT` only. Plain-HTTP proxy requests get `405`.
- IPv4 (A records) only. DNS results are cached in memory until the proxy restarts.
- Built for Windows, but `steam_proxy.py` itself works on any OS.
