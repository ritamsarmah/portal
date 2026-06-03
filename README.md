# Portal

A collection of various programs that run on a custom circular display.

## Installation

To build and deploy to a Raspberry Pi:

1. Install [Odin](https://odin-lang.org/) compiler on local machine.
2. Update Makefile `HOST` and `HOME` variables.
3. Run `make dependencies` to install dependencies on Raspberry Pi.
4. Run `make deploy` to build and upload to Raspberry Pi.
5. Add `.env` file with following information:

```
HA_URL=
HA_MEDIA_ENTITY=
HA_TOKEN=
```

To run with "remote control" functionality and auto-start on boot:

1. Enable console auto-login via `sudo raspi-config` (System Options > Auto Login > Console Autologin)
2. Copy `server.sh` to the Raspberry Pi and add the following to `.profile`:

```sh
if [ "$(tty)" = "/dev/tty1" ]; then
  exec ./server.sh
fi
```

3. Reboot. Use `client.sh` to remotely change the scene.
