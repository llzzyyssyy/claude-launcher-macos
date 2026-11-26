# Changelog

## 1.1.3 - 2026-11-26

- Tailscale readiness now comes from `tailscale status --json`: the backend is Running, this Mac is online, and an exit node is selected and online. The system VPN switch is ignored, because On Demand can report Connected while the backend is Stopped.
- Open Tailscale.app when it is not running. A stopped backend is brought up with `tailscale up`, keeping the saved exit node. The non-default-flags error is retried with the command Tailscale prints, and `--reset` is not used.
- Clash Verge Rev service mode: ask the local mihomo controller to turn TUN off, then stop if a 198.18.x interface or default route is still present. Macs without that service are unchanged.
- The region check remains the only hard stop. Timezone, DNS, and IPv6 checks warn without blocking launch.
- Write each step to `~/Library/Logs/ClaudeLauncher/launcher.log` without secrets.

## 1.1.2 - 2026-11-11

- Added a standard About window with version, copyright, and contact details.
- Displayed the release version in the main window.
- Kept native Dock minimization and movable macOS window behavior.

## 1.1.1 - 2026-11-11

- Replaced the accessory panel with a standard macOS window.
- Fixed Dock minimization and title bar dragging.

## 1.1.0 - 2026-11-11

- Added the ordered one-click workflow and manual launch path.
- Removed browser-based IP checks.
- Renamed the app to Claude 启动器.
