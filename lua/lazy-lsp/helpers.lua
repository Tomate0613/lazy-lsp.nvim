local function replace_first(list, replacement)
  local result = vim.list_slice(list, 2)
  table.insert(result, 1, replacement)
  return result
end

local function escape_shell_arg(arg)
  return "'" .. string.gsub(arg, "'", "'\"'\"'") .. "'"
end

local function escape_shell_args(args)
  local escaped = {}
  for _, arg in ipairs(args) do
    table.insert(escaped, escape_shell_arg(arg))
  end
  return table.concat(escaped, " ")
end

local cache_nix_command_available = nil
-- Check whether both `nix` command and `nixpkgs` flake are available
---@return boolean?
local function nix_command_available()
  if cache_nix_command_available ~= nil then
    return cache_nix_command_available
  end
  cache_nix_command_available = false

  local registry = vim.fn.system({ "nix", "registry", "list", "--offline" })
  if vim.v.shell_error == 0 then
    for flake in vim.gsplit(registry, "\n") do
      local flake_url = string.match(flake, "^%S+ flake:nixpkgs (.*)")
      if flake_url then
          cache_nix_command_available = true
        break
      end
    end
  end
  return cache_nix_command_available
end

---@param nix_pkgs string[]
---@param cmd string[]
---@param channel string
---@return string[]
local function in_shell(nix_pkgs, cmd, channel)
  if #nix_pkgs == 0 then
    error("No nix pkg provided")
    return {}
  end

  local nix_cmd = {}
  if nix_command_available() then
    nix_cmd = { "nix", "shell" }
    for _, nix_pkg in ipairs(nix_pkgs) do
      table.insert(nix_cmd, channel .. "#" .. nix_pkg)
    end
    table.insert(nix_cmd, "--command")
    vim.list_extend(nix_cmd, cmd)
  else
    nix_cmd = { "nix-shell", "-p" }
    vim.list_extend(nix_cmd, nix_pkgs)
    table.insert(nix_cmd, "--run")
    table.insert(nix_cmd, escape_shell_args(cmd))
  end
  return nix_cmd
end

---@param pkg string
---@param callback fun(path: string)
---@param channel string? Default: "nixpkgs"
local function nix_store_path(pkg, callback, channel)
  if not nix_command_available() then
    error("nix_store_path requires the nix command to be available")
  end

  local cmd = { "nix", "eval", "--raw", (channel or "nixpkgs") .. "#" .. pkg .. ".outPath" }

  vim.system(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data and #data > 0 then
        callback(vim.trim(data[1]))
      end
    end,
    on_stderr = function(_, data)
      if data then
        local filtered = {}
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(filtered, line)
          end
        end
        if #filtered > 0 then
          vim.notify("nix eval: " .. table.concat(filtered, "\n"), vim.log.levels.WARN)
        end
      end
    end,
  })
end

return {
  in_shell = in_shell,
  nix_store_path = nix_store_path,
}
