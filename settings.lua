return {
    languageServers = {
        c =          "clangd",
        crystal =    "crystalline",
        go =         "gopls",
        haskell =    "haskell-language-server-wrapper --lsp",
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
    showDiagnostics = {
        error = false,
        warning = false,
        information = false,
        hint = false
    },
    tabAutocomplete = false
}
