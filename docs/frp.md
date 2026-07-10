# Ephemeral demo tunnels

FRP exposes a local HTTP server at a temporary public hostname below
`proxy.yadunut.dev`. Demo pages are public: never expose credentials,
privileged development tools, or sensitive data.

## Open a tunnel

Start the local service, for example on `127.0.0.1:3000`, then choose a unique
lowercase DNS label. A label is 1-63 letters, digits, or hyphens; it must begin
and end with a letter or digit. `tunnel` is reserved.

The initial authorized key is `~/.ssh/yadunut` with fingerprint:

```text
SHA256:Gc/MTS5ohuH63ykbxBRCKElmyF/3cL9hwALBYikHzVI
```

Connect with:

```sh
ssh -T \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o IdentitiesOnly=yes \
  -i ~/.ssh/yadunut \
  -p 2200 \
  -R :80:127.0.0.1:3000 \
  v0@tunnel.proxy.yadunut.dev \
  http \
  --proxy_name demo \
  --sd demo
```

On first use, compare the SSH host-key fingerprint printed by the client with
the deployment fingerprint below before accepting it. Wait for FRP's success
banner before sharing `https://demo.proxy.yadunut.dev`.

Stop the SSH process to remove the tunnel. A graceful stop should remove it
promptly; cleanup after an ungraceful network failure has no guaranteed bound.

## Deployment identity

SSH host-key fingerprint:

```text
SHA256:9csKTmNk8qEaArwWCV1tx7ZhwNQbTDrQV/RXGQ8JObc
```

The host key and FRP control token live in the 1Password `cluster/frp` item.
Rotating either value requires restarting FRP and terminates all active demos.
