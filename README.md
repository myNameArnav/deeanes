<img src="docs/icon.png" width="96" alt="">

# Deeanes

A tiny macOS menu bar app for switching system-wide DNS servers in one click, with live latency for each server.

<img src="docs/screenshot.png" width="320" alt="Deeanes menu showing DNS presets with latency and jitter">

- **One click, whole system.** Applies to every enabled network service (Wi-Fi, Ethernet, USB tethering). VPN services like Tailscale manage their own DNS and are left alone.
- **Live latency.** While the menu is open, every server gets a real DNS query each second, with jitter and packet loss over the last 30 s. Your router's row ("Automatic") is a quick read on Wi-Fi quality.
- **Ad-block detection.** A shield marks servers that block ads.
- **Interception warning.** A red line appears if your network or ISP is secretly answering DNS for you.
- **Menu bar badge.** Shows which server is active (`CF`, `G`, …), including after changes made in System Settings.
- **Editable list.** Rename, reorder, add, or remove servers, and set your own badge, in Edit Servers.

It uses nothing at idle: 0% CPU, about 14 MB of memory, and no network traffic until you open the menu.

## Install

1. Download `Deeanes-<version>.dmg` from [Releases](../../releases), open it, and drag Deeanes to Applications. A `.zip` is also there if you prefer.
2. Open Deeanes from Applications.
3. The app is not notarized, so macOS blocks the first launch. Allow it in **System Settings → Privacy & Security → Open Anyway**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Deeanes.app
   ```

You need an admin account on the Mac. Deeanes changes DNS through macOS's `networksetup` and doesn't need a helper or your password. It requires an Apple Silicon Mac with macOS 13 or later.

## Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`):

```sh
./build.sh                   # → build/Deeanes.app
./dist.sh                    # → build/Deeanes-<version>.dmg and .zip (DMG needs uv)
swift tools/make-icon.swift  # regenerates Resources/AppIcon.icns
```

## Notes

- If a VPN with its own DNS is on (for example Tailscale with "Use Tailscale DNS"), the menu shows "In use: …". In that case, the VPN may override the server you pick.
- Encrypted DNS (DoH/DoT) is not supported yet.

Built almost entirely with AI coding agents.

## License

[GPL-3.0](LICENSE)
