-- defaults for omitted server options (you probably don't want to change these)
local defaultLanguageServerOptions = {
    -- Unique name for the server to be shown in statusbar and logs
    -- Defaults to the same as cmd if omitted
    shortName = nil,

    -- (REQUIRED) command to execute the language server
    cmd = "",

    -- Arguments for the above command
    args = {},

    -- Language server specific options that are sent to the server during
    -- initialization – you can usually omit this field
    initializationOptions = nil,

    -- callback function that is called when language server is initialized
    -- (useful for debugging and disabling server capabilities)
    -- For example to disable getting hover information from a server:
    -- onInitialized = function(client)
    --     client.serverCapabilities.hoverProvider = false
    -- end
    onInitialized = nil,
}

-- Pre-made configurations for commonly used language servers – you can also
-- define your own servers to be used in settings at the bottom of this file.
-- See defaultLanguageServerOptions above for the available options.
languageServer = {
    clangd = {
        cmd = "clangd"
    },
    clojurelsp = {
        cmd = "clojure-lsp"
    },
    crystalline = {
        cmd = "crystalline"
    },
    deno = {
        cmd = "deno",
        args = {"lsp"}
    },
    gopls = {
        cmd = "gopls"
    },
    hls = {
        shortName = "hls",
        cmd = "haskell-language-server-wrapper",
        args = {"--lsp"}
    },
    julials = {
        shortName = "julials",
        cmd = "julia",
        args = {"--startup-file=no", "--history-file=no", "-e", "using LanguageServer; runserver()"}
    },
    lualsp = {
        cmd = "lua-lsp"
    },
    pylsp = {
        cmd = "pylsp"
    },
    pyright = {
        shortName = "pyright",
        cmd = "pyright-langserver",
        args = {"--stdio"}
    },
    quicklintjs = {
        cmd = "quick-lint-js",
        args = {"--lsp"}
    },
    rubocop = {
        cmd = "rubocop",
        args = {"--lsp"}
    },
    ruff = {
        cmd = "ruff-lsp",
        onInitialized = function(client)
            -- does not give useful results
            client.serverCapabilities.hoverProvider = false
        end
    },
    rustAnalyzer = {
        shortName = "rust",
        cmd = "rust-analyzer"
    },
    solargraph = {
        cmd = "solargraph",
        args = {"stdio"}
    },
    zls = {
        cmd = "zls"
    }
}

-- you don't need to care about this part but it's basically filling in defaults
-- for all missing fields in language servers defined above
defaultLanguageServerOptions.__index = defaultLanguageServerOptions
for _, server in pairs(languageServer) do
    setmetatable(server, defaultLanguageServerOptions)
end


settings = {

    -- Use LSP completion in place of micro's default Autocomplete action when
    -- available (you can bind `command:autocomplete` command to a different
    -- key in ~/.config/micro/bindings.json even if this setting is false)
    tabAutocomplete = false,

    -- Automatically start language server(s) when a buffer with matching
    -- filetype is opened
    autostart = {
        -- Example #1: Start gopls when editing .go files:
        -- go = { languageServer.gopls },

        -- Example #2: Start pylsp AND ruff-lsp when editing Python files:
        -- python = { languageServer.pylsp, languageServer.ruff },
    },

    -- Language server to use when `lsp` command is executed without args
    defaultLanguageServer = {
        c          = languageServer.clangd,
        clojure    = languageServer.clojurelsp,
        crystal    = languageServer.crystalline,
        go         = languageServer.gopls,
        haskell    = languageServer.hls,
        javascript = languageServer.deno,
        julia      = languageServer.julials,
        json       = languageServer.deno,
        lua        = languageServer.lualsp,
        markdown   = languageServer.deno,
        python     = languageServer.pylsp,
        ruby       = languageServer.solargraph,
        rust       = languageServer.rustAnalyzer,
        typescript = languageServer.deno,
        zig        = languageServer.zls,
    },

    -- Which kinds of diagnostics to show in the gutter
    showDiagnostics = {
        error       = false,
        warning     = false,
        information = false,
        hint        = false
    },
}
