local helpers = require("lazy-lsp.helpers")
local overrides = require("lazy-lsp.overrides")

local defaults = {
  servers = require("lazy-lsp.servers"),
  channel = "nixpkgs",
  preferred_servers = {},
  excluded_servers = {},
  disabled_servers = {},
}

local function setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts)

  for server, pkgs in pairs(opts.servers) do
    if pkgs and pkgs ~= "" and not vim.tbl_contains(opts.excluded_servers, server) then
      local config = vim.tbl_deep_extend("force", vim.lsp.config[server] or {}, overrides[server] or {})

      if config ~= nil and type(config.cmd) == "table" then
        vim.lsp.config(server, { cmd = helpers.in_shell(type(pkgs) == "string" and { pkgs } or pkgs, config.cmd, opts.channel) })
      end

      if config ~= nil and type(config.filetypes) == "table" then
        local filetypes = vim.tbl_filter(function(lang)
          return opts.preferred_servers[lang] == nil
        end, config.filetypes)

        for lang, preferred_servers in pairs(opts.preferred_servers) do
          if vim.tbl_contains(preferred_servers, server) then
            table.insert(filetypes, lang)
          end
        end

        vim.lsp.config(server, { filetypes = filetypes })
      end

      if not vim.tbl_contains(opts.disabled_servers, server) then
        vim.lsp.enable(server)
      end
    end
  end
end

return {
  setup = setup,
  in_shell = helpers.in_shell,
  nix_store_path = helpers.nix_store_path,
}
