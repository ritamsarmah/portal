# Portal

A collection of various programs that run on a custom display.

## Installation

To build and deploy to a Raspberry Pi:

1. Install [Odin](https://odin-lang.org/) compiler on local machine.
2. Update Makefile `HOST` and `REMOTE` variables.
3. Run `make dependencies` to install dependencies on Raspberry Pi.
4. Run `make deploy` to build and upload to Raspberry Pi.
5. Add `.env` file with following information:

```
HA_URL=
HA_MEDIA_ENTITY=
HA_TOKEN=
```

6. To auto-start on boot, enable console auto-login via `sudo raspi-config` (System Options > Auto Login > Console Autologin) and add the following to `.profile`:

```sh
if [ "$(tty)" = "/dev/tty1" ]; then
  set -a
  . .env
  set +a

  exec ./portal
fi
```

7. Reboot.
