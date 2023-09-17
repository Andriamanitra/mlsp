# µlsp

LSP client for [micro-editor](https://github.com/zyedidia/micro). Note that this
is work in progress and currently **extremely buggy**, even the basic features
don't work properly yet. Use at your own risk.

[AndCake/micro-plugin-lsp](https://github.com/AndCake/micro-plugin-lsp)
is a slightly more complete LSP client for micro.


## Installation

Clone the repository to your micro plugins directory:

```
git clone https://github.com/Andriamanitra/mlsp ~/.config/micro/plug/mlsp
```

The plugin currently provides two commands:
* `lsp` starts a language server. If you run it without arguments the plugin
  tries to guess the right server by type of the currently open file, but you
  can also give it a command to run to launch any language server of your
  choice, for example `lsp "deno lsp"` (the quotes are required if the command
  takes arguments).
* `hover` shows hover information for the code under cursor

You can type the commands on micro command prompt or bind them to keys by
adding something like this to your `bindings.json`:
```json
{
    "F7": "command:lsp",
    "Ctrl-j": "command:hover"    
}
```


## Supported features

* [x] get hover information
* [ ] everything else
