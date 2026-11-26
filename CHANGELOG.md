# Changelog

## 1.1.6 - 2026-11-26

- Restyled 「一键启动」 and 「一键关闭」 as short rectangles with a 7pt corner radius. Launch is a quiet accent fill; shutdown is a tinted outline instead of a solid red pill. Removed the caption under the buttons; that note is now the shutdown button’s help text. Shutdown behavior is unchanged.

## 1.1.5 - 2026-11-26

- Made 「一键关闭」 the same size and weight as 「一键启动」: both are filled buttons, side by side at the top. Shutdown uses a red fill. Shutdown behavior is unchanged.

## 1.1.4 - 2026-11-26

- Added a one-click shutdown. It quits Claude, runs `tailscale down` (WantRunning false, saved exit node kept, no `--reset`), then quits Tailscale.app.
- Shutdown confirms `BackendState` is no longer Running. It does not turn Clash or its TUN back on.
- The system VPN switch can stay on because Tailscale rewrites On Demand. Traffic stops using the exit node once the backend is down.

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
