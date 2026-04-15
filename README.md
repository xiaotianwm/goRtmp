# goRtmp

Ubuntu amd64 binary release for `goRtmp`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xiaotianwm/goRtmp/main/install.sh | sudo bash
```

## Update

```bash
curl -fsSL https://raw.githubusercontent.com/xiaotianwm/goRtmp/main/update.sh | sudo bash
```

## Diagnose

```bash
curl -fsSL https://raw.githubusercontent.com/xiaotianwm/goRtmp/main/diag.sh | sudo bash
```

Optional protected endpoint checks:

```bash
curl -fsSL https://raw.githubusercontent.com/xiaotianwm/goRtmp/main/diag.sh | sudo env AUTH_COOKIE=your_cookie_value bash
```

## Defaults

- Install dir: `/opt/goRtmp`
- Service name: `goRtmp`
- Server config: `/opt/goRtmp/server/app.env`
- Web config: `/opt/goRtmp/web/app.env`
- Local diag script: `/opt/goRtmp/diag.sh`

The web service only uses assets embedded in the `web` binary.
Runtime external static directories are not used.

The scripts download the latest GitHub Release asset:

`goRtmp-linux-amd64.tar.gz`
