local helpers = require("lazy-lsp.helpers")
local overrides = require("lazy-lsp.overrides")

local defaults = {
  servers = require("lazy-lsp.servers"),
  channel = "nixpkgs",
  preferred_servers = {},
  excluded_servers = {},
  disabled_servers = {},
}

local function is_list(t)
  if type(t) ~= "table" then
    return false
  end

  local i = 1
  for k, _ in pairs(t) do
    if k ~= i then
      return false
    end
    i = i + 1
  end

  return true
end

local function setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts)

  for server, pkgs in pairs(opts.servers) do
    if pkgs and pkgs ~= "" and not vim.tbl_contains(opts.excluded_servers, server) then
      local pkgs_list = is_list(pkgs) and pkgs or { pkgs }
      local override = overrides[server]

      if type(override) == "function" then
        override = override(pkgs_list, opts)
      end

      local config = vim.tbl_deep_extend("force", vim.lsp.config[server] or {}, override or {})

      if config ~= nil then
        local cmd = nil

        if type(config.cmd) == "table" then
          cmd = helpers.in_shell(pkgs_list, config.cmd, opts.channel)
        else
          vim.lsp.log.info(server .. " not supported by lazy-lsp bc cmd is of type " .. type(config.cmd))
        end

        if cmd ~= nil then
          vim.lsp.config(server, { cmd = cmd })
        elseif override then
          vim.lsp.config(server, override)
        end
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
