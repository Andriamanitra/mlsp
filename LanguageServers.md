# List of language servers & how to get them

* [C/C++](#cc)
* [Clojure](#clojure)
* [Crystal](#crystal)
* [Go](#go)
* [Haskell](#haskell)
* [JavaScript/TypeScript](#javascripttypescript)
* [JSON](#json)
* [Lua](#lua)
* [Markdown](#markdown)
* [Python](#python)
* [Ruby](#ruby)
* [Rust](#rust)
* [Scala](#scala)
* [Zig](#zig)

## C/C++

- [Clangd](https://clangd.llvm.org/)
  - Installation: [instructions](https://clangd.llvm.org/installation.html)
  - Command: `clangd`

## Clojure

- [clojure-lsp](https://github.com/clojure-lsp/clojure-lsp)
  - Installation: [instructions](https://clojure-lsp.io/installation/)
  - Command: `clojure-lsp`

## Crystal

- [Crystalline](https://github.com/elbywan/crystalline)
  - Installation:
    [instructions](https://github.com/elbywan/crystalline#global-install)
  - Command: `crystalline`

## Go

- [gopls](https://pkg.go.dev/golang.org/x/tools/gopls)
  - Installation:
    [instructions](https://pkg.go.dev/golang.org/x/tools/gopls#readme-installation)
  - Command: `gopls`

## Haskell

- [HLS](https://github.com/haskell/haskell-language-server)
  - Installation: use [ghcup](https://www.haskell.org/ghcup/)
  - Command: `haskell-language-server-wrapper --lsp`

## JavaScript/TypeScript

- [biome](https://github.com/biomejs/biome)
  - Installation:
    [instructions](https://biomejs.dev/guides/getting-started/#installation)
  - Command: `biome lsp-proxy`

- [deno](https://github.com/denoland/deno)
  - Installation:
    [instructions](https://github.com/denoland/deno_install/blob/master/README.md#deno_install)
  - Command: `deno lsp`

- [quick-lint-js](https://github.com/quick-lint/quick-lint-js)
  - Only diagnostics (no formatting, hover information or code navigation)
  - Installation: `npm install -g quick-lint-js`
  - Command: `quick-lint-js --lsp`

## JSON

- [deno](https://github.com/denoland/deno)
  - Installation:
    [instructions](https://github.com/denoland/deno_install/blob/master/README.md#deno_install)
  - Command: `deno lsp`

## Lua

- [luals](https://github.com/luals/lua-language-server)
  - Installation: [instructions](https://luals.github.io/#other-install)
  - Command: `lua-language-server` (make sure the executable was installed in your $PATH)
- [lua-lsp](https://github.com/Alloyed/lua-lsp)
  - Unmaintained. You are in for trouble if you want to get it to work with Lua
    5.4.
  - Installation: `luarocks install lua-lsp`
    ([luarocks](https://github.com/luarocks/luarocks))
  - Command: `lua-lsp`

## Markdown

- [deno](https://github.com/denoland/deno)
  - Installation:
    [instructions](https://github.com/denoland/deno_install/blob/master/README.md#deno_install)
  - Command: `deno lsp`
- [marksman](https://github.com/artempyanykh/marksman)
  - Installation:
    [instructions](https://github.com/artempyanykh/marksman/blob/main/docs/install.md)
  - Command: `marksman server`

## Python

- [pylsp](https://github.com/python-lsp/python-lsp-server)
  - Installation: `pip install python-lsp-server[all]`
  - Command: `pylsp`

- [Pyright](https://github.com/microsoft/pyright)
  - Installation: `npm install -g pyright`
  - Command: `pyright-langserver --stdio`

- [ruff](https://github.com/astral-sh/ruff)
  - Only diagnostics, formatting and code actions (no hover information or code navigation)
  - Installation: `pip install ruff`
  - Command: `ruff server`

## Ruby

- [ruby-lsp](https://github.com/Shopify/ruby-lsp)
  - Installation: `gem install ruby-lsp`
  - Command: `ruby-lsp`

- [solargraph](https://github.com/castwide/solargraph)
  - Installation: `gem install solargraph`
  - Command: `solargraph stdio`

## Rust

- [rust-analyzer](https://github.com/rust-lang/rust-analyzer)
  - Installation: `rustup component add rust-analyzer`
  - Command: `rust-analyzer`

## Scala

- [metals](https://github.com/scalameta/metals)
  - Installation: (requires [coursier](https://get-coursier.io/docs/cli-installation)) command: `coursier install metals`
  - Command: `metals`

## Zig

- [zls](https://github.com/zigtools/zls)
  - Installation: [instructions](https://github.com/zigtools/zls#installation)
  - Command: `zls`
