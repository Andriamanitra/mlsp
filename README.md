# µlsp

LSP client for [micro-editor](https://github.com/zyedidia/micro). Note that this
is work in progress and currently **extremely buggy**, even the basic features
don't work properly yet. Use at your own risk.

[AndCake/micro-plugin-lsp](https://github.com/AndCake/micro-plugin-lsp) is a
slightly more complete LSP client for micro.

## Demo

[https://asciinema.org/a/610761](https://asciinema.org/a/610761)

## Installation

Simply clone the repository to your micro plugins directory:

```
git clone https://github.com/Andriamanitra/mlsp ~/.config/micro/plug/mlsp
```

You will also need to install [language servers](LanguageServers.md) for the
programming languages you want to use.

The plugin currently provides following commands:

- `lsp "deno lsp"` (the quotes are required when the command takes arguments)
  starts a language server by executing command `deno lsp`. Without arguments
  the `lsp` command will try to guess the right server by looking at the
  currently open filetype.
- `lsp-stop "deno lsp"` stops the `deno lsp` language server. Without arguments
  the `lsp-stop` command will stop _all_ currently running language servers.
- `hover` shows hover information for the code under cursor
- `format` formats the buffer that is currently open
- `autocomplete` for code completion suggestions. PROTIP: If you wish to use the
  same key as micro's autocompletion (tab by default), enable `tabAutocomplete`
  in `settings.lua` instead of binding `command:autocomplete` to a key!
- `goto-definition` – open the definition for the symbol under cursor
- `goto-declaration` – open the declaration for the symbol under cursor
- `goto-typedefinition` – open the type definition for the symbol under cursor
- `goto-implementation` – open the implementation for the symbol under cursor

You can type the commands on micro command prompt or bind them to keys by adding
something like this to your `bindings.json`:

```json
{
  "F7": "command:lsp",
  "F8": "command:format",
  "Ctrl-j": "command:hover"
}
```

## Supported features

- [x] get hover information
- [x] show diagnostics (disabled by default, edit `settings.lua` to enable)
- [x] autocomplete using tab (disabled by default, edit `settings.lua` to enable)
- [x] format document
- [x] format selection
- [x] go to definition
- [x] go to declaration
- [x] go to implementation
- [x] go to type definition
- [ ] find references
- [ ] everything else

## Showing LSP information on statusline

The plugin provides a function `mlsp.status` that can be used in the status line format.
Here is an example configuration (`~/.config/micro/settings.json`) that uses it:

```json
{
    "statusformatl": "$(filename) $(modified)($(line),$(col)) | ft:$(opt:filetype) | µlsp:$(mlsp.status)"
}
```

See [micro documentation](https://github.com/zyedidia/micro/blob/master/runtime/help/options.md)
and the built-in [status plugin](https://github.com/zyedidia/micro/blob/master/runtime/plugins/status/help/status.md)
for all possible options.

## Known issues

- When using multiple language servers at the same time there is no good way to
  specify which server should handle which types of requests. Until this is
  addressed you should make sure to start the language servers in order of
  preference, because only the first one that can handle the request type will
  be used. For example if you start `pylsp` before `ruff-lsp` you will get better
  hover information.
