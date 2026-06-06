package main

import (
	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	// Plug in the standard Caddy modules.
	_ "github.com/caddyserver/caddy/v2/modules/standard"
)

func main() {
	caddycmd.Main()
}
