# Security

## Reporting a vulnerability

Please do not publish a security vulnerability as a public issue before it has
been reviewed. Send a concise report to `roylau3366@gmail.com`, including the
affected version, reproduction steps, and expected impact.

## Security boundaries

- The app changes local VPN state and may terminate VPN applications selected
  by its matching rules. Review the source before running it on a work device.
- The region check reads the network response from
  `https://claude.ai/cdn-cgi/trace`. It does not inspect account status and does
  not guarantee that every Claude connection uses the same route.
- Release builds made by the project build script use ad hoc signing. They are
  not notarized by Apple.
