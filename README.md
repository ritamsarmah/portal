# Portal

A collection of various programs that run on a custom display.

## Installation

To build and deploy to a Raspberry Pi:

1. Install [Odin](https://odin-lang.org/) compiler on local machine.
2. Install dependencies on the Raspberry Pi: `sudo apt install libsdl3-dev libsdl3-image-dev libcurl4-openssl-dev`.
3. Run `make deploy`.
4. Add `.env` file with following information:

```
HA_MEDIA_URL=
HA_TOKEN=
```
