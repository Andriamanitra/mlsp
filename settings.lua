diagnosticSeverity = {
    none = 0,
    error = 1,
    warning = 2,
    information = 3,
    hint = 4,
}

return {
    languageServers = {
        crystal =    "crystalline",
        go =         "gopls",
        haskell =    "haskell-language-server-wrapper",
        javascript = "deno lsp",
        json =       "deno lsp",
        lua =        "lua-lsp",
        markdown =   "deno lsp",
        python =     "pylsp",
        rust =       "rust-analyzer",
        typescript = "deno lsp",
        zig =        "zls",
    },
    showDiagnostics = diagnosticSeverity.none
}
