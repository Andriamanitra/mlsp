diagnosticSeverity = {
    none = 0,
    error = 1,
    warning = 2,
    information = 3,
    hint = 4,
}

return {
    languageServers = {
        c =          "clangd",
        crystal =    "crystalline",
        go =         "gopls",
        haskell =    "haskell-language-server-wrapper",
        javascript = "deno lsp",
        json =       "deno lsp",
        lua =        "lua-lsp",
        markdown =   "deno lsp",
        python =     "pylsp",
        ruby =       "solargraph stdio",
        rust =       "rust-analyzer",
        typescript = "deno lsp",
        zig =        "zls",
    },
    showDiagnostics = diagnosticSeverity.none
}
