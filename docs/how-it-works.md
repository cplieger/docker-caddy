# How docker-caddy is built

This page describes how the image is assembled and what that means for Caddy's behavior. It is for readers who want to know how close the image is to the official one. [CONTRIBUTING.md](../CONTRIBUTING.md) has the build stages in detail.

## Built from the official builder

The binary is compiled in the official `caddy` builder image with [xcaddy](https://github.com/caddyserver/xcaddy), the tool Caddy's maintainers provide for adding plugins. The two plugins are pinned by version in the Dockerfile. Everything else in the binary is the Caddy release the builder carries.

The amd64 and arm64 images each compile on hardware of their own architecture, with no emulation.

## The rest of Caddy's image, copied over

The build copies four things from the official `caddy` runtime image. They are the default Caddyfile, the welcome page, the MIME table at `/etc/mime.types` and the `/config` and `/data` state folders. Changes Caddy's maintainers make to them reach this image with ordinary image updates.

The `XDG_CONFIG_HOME=/config` and `XDG_DATA_HOME=/data` variables are declared by hand, because a copy moves files and not an image's environment. `XDG_DATA_HOME` is what makes `/data` the certificate store. The build stops if the official image ever declares different values, or a different working folder than `/srv`.

## One Caddy version

The builder image and the runtime image carry their own digest pins, which Renovate moves in separate pull requests. The build stops when the built binary and the runtime image report different Caddy versions. So the image never pairs the binary of one release with the files of another.

For the same reason this image does not declare `CADDY_VERSION`, unlike the official image. A copied version string could name a release the shipped binary is not. A Caddyfile that reads `{env.CADDY_VERSION}` gets an empty value here and keeps serving.

## The runtime

The final image is `gcr.io/distroless/static` with two executables, `caddy` and the `/probe` healthcheck binary. `caddy` runs as PID 1 with the official image's command, `caddy run --config /etc/caddy/Caddyfile --adapter caddyfile`, so the container's exit status is Caddy's own.
