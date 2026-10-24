<p align="center">
  <img src="assets/coffee.svg" width="112" height="112" alt="pmSip coffee cup">
</p>

# pmSip

A tiny macOS menu bar app that keeps your Mac awake with one click and a questionable amount of coffee.

Under the hood, it toggles `sudo pmset -a disablesleep 1/0`. Same command, less typing. Your terminal can take a break. Your Mac can't. Until you click again.

## Why pmSip?

**pm** comes from `pmset`, the macOS power management command doing the actual work. **Sip** is a sip of coffee. Put them together and you get a coffee cup with root privileges. Very responsible.

## How it works

- **Left-click** to toggle sleep prevention.
- **Filled brown cup:** sleep prevention is on. Your Mac has had its coffee.
- **Outline cup:** normal sleep is allowed. Bedtime is back on the table.
- **Red cup:** something went wrong. Hover for the error. If the sleep setting is unknown, clicking only retries reading it.
- **Right-click** to quit. Quitting does not reset the sleep setting, so turn sleep prevention off first if you're done.

Errors appear in the icon's tooltip. If a toggle fails, hover over the cup to see what went wrong.

pmSip checks the system setting at startup, after wake, and every 30 seconds in the background. Clicks start the toggle immediately, without an extra read beforehand. Once the command succeeds, the cup updates and pmSip checks the result in the background. External changes can take until the next refresh to appear.

## Installation

Requires **macOS 13 or later**.

Follow [INSTALL.md](INSTALL.md) to install the app and set up the two allowed `sudo` commands. It's a one-time terminal setup. After that, just click the cup.

pmSip never asks for or stores your password. The setup password prompt belongs to `sudo` in your terminal.

## Build and run

Open the project in Xcode and press Cmd+R:

```sh
open pmSip.xcodeproj
```

Or build from the terminal:

```sh
xcodebuild -project pmSip.xcodeproj -scheme pmSip -configuration Debug build
```

The Xcode project is included. If you change `project.yml`, regenerate it with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
```

## Launch at login

Add your installed copy to Login Items in macOS System Settings. pmSip does not add itself.

## License

[MIT](LICENSE) © 2026 leminkozey. Use it, change it, ship it. Keep the copyright and license notice with it.
