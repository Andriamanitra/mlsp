# µlsp

LSP client for [micro-editor](https://github.com/zyedidia/micro).
Note that this is a work in progress and has not yet been tested extensively – expect there to be some bugs.
Please [open an issue](https://github.com/Andriamanitra/mlsp/issues/new) if you run into any!


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

- `lsp deno lsp` starts a language server by executing command `deno lsp`.
  Without arguments the `lsp` command will try to guess the right server by
  looking at the currently open filetype.
- `lsp-stop deno` stops the language server with name `deno`. Without arguments
  the `lsp-stop` command will stop _all_ currently running language servers.
- `hover` shows hover information for the code under cursor.
- `format` formats the buffer that is currently open.
- `autocomplete` for code completion suggestions. PROTIP: If you wish to use the
  same key as micro's autocompletion (tab by default), enable `tabAutocomplete`
  in `config.lua` instead of binding `command:autocomplete` to a key!
- `goto-definition` – open the definition for the symbol under cursor
- `goto-declaration` – open the declaration for the symbol under cursor
- `goto-typedefinition` – open the type definition for the symbol under cursor
- `goto-implementation` – open the implementation for the symbol under cursor
- `find-references` - find all references to the symbol under cursor (shows the results in a new pane)

You can type the commands on micro command prompt or bind them to keys by adding
something like this to your `bindings.json`:

```json
{
  "F7": "command:lsp",
  "F8": "command:format",
  "Alt-h": "command:hover",
  "Alt-d": "command:goto-definition",
  "Alt-r": "command:find-references"
}
```


## Supported features

- [x] get hover information
- [x] show diagnostics (disabled by default, edit `config.lua` to enable)
- [x] autocomplete using tab (disabled by default, edit `config.lua` to enable)
- [x] format document
- [x] format selection
- [x] go to definition
- [x] go to declaration
- [x] go to implementation
- [x] go to type definition
- [x] find references
- [ ] rename symbol
- [ ] code actions
- [ ] incremental document synchronization (better performance when editing large files)
- [ ] [suggest a feature](https://github.com/Andriamanitra/mlsp/issues/new)


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
for more information on customizing the statusline.


## Known issues

- When using multiple language servers at the same time there is no good way to
  specify which server should handle which types of requests.


## Other similar projects

* [AndCake/micro-plugin-lsp](https://github.com/AndCake/micro-plugin-lsp) is another LSP plugin for micro-editor.
