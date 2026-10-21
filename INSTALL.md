# Installation

Requires macOS 13 or later.

## Install the app

Build pmSip using the instructions in [README.md](README.md), then copy `pmSip.app` from the build products to your Applications folder and open it. The coffee cup appears in the menu bar.

## Allow sleep toggling

pmSip uses `sudo -n` to run two specific `pmset` commands. Configure access once so clicking the icon does not require a password.

Find your macOS account name:

```sh
whoami
```

Open the sudoers file:

```sh
sudo visudo -f /etc/sudoers.d/pmset-disablesleep
```

Enter your Mac administrator password when prompted. Terminal does not display characters while you type. pmSip never asks for or stores your password.

Add this line, replacing `YOUR_USERNAME` with the output of `whoami`:

```sudoers
YOUR_USERNAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

Save and close the editor. With the default vi editor, press `i` before entering the line, then press Escape, type `:wq`, and press Return to save. `visudo` checks the syntax; fix any reported errors rather than forcing the file to be saved.

This rule allows any process running under your account to execute these two commands as root without a password. It does not grant passwordless access to other commands.

## Use pmSip

- Left-click the coffee cup to toggle sleep prevention.
- A filled brown cup means sleep prevention is enabled.
- An outline means normal sleep is allowed.
- Right-click to quit. Quitting does not reset the sleep setting.

If the toggle fails, hover over the icon to read the error and check the sudoers rule above.

## Launch at login

Add your installed copy of pmSip to Login Items in macOS System Settings.
