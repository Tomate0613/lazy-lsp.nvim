local helpers = require("lazy-lsp.helpers")

return {
  omnisharp = {
    cmd = {
      "OmniSharp",
      "-z", -- https://github.com/OmniSharp/omnisharp-vscode/pull/4300
      "--hostPID",
      tostring(vim.fn.getpid()),
      "DotNet:enablePackageRestore=false",
      "--encoding",
      "utf-8",
      "--languageserver",
    },
  },
  jdtls = function(pkgs_list, opts)
    local function get_jdtls_cache_dir()
      return vim.fn.stdpath("cache") .. "/jdtls"
    end

    local function get_jdtls_workspace_dir()
      return get_jdtls_cache_dir() .. "/workspace"
    end

    local function get_jdtls_config_dir()
      return get_jdtls_cache_dir() .. "/config"
    end

    local function get_jdtls_jvm_args()
      local env = os.getenv("JDTLS_JVM_ARGS")
      local args = {}
      for a in string.gmatch((env or ""), "%S+") do
        local arg = string.format("--jvm-arg=%s", a)
        table.insert(args, arg)
      end
      return unpack(args)
    end

    local root_markers1 = {
      -- Multi-module projects
      "mvnw", -- Maven
      "gradlew", -- Gradle
      "settings.gradle", -- Gradle
      "settings.gradle.kts", -- Gradle
      -- Use git directory as last resort for multi-module maven projects
      -- In multi-module maven projects it is not really possible to determine what is the parent directory
      -- and what is submodule directory. And jdtls does not break if the parent directory is at higher level than
      -- actual parent pom.xml so propagating all the way to root git directory is fine
      ".git",
    }
    local root_markers2 = {
      -- Single-module projects
      "build.xml", -- Ant
      "pom.xml", -- Maven
      "build.gradle", -- Gradle
      "build.gradle.kts", -- Gradle
    }

    return {
      ---@param dispatchers? vim.lsp.rpc.Dispatchers
      ---@param config vim.lsp.ClientConfig
      cmd = function(dispatchers, config)
        local workspace_dir = get_jdtls_workspace_dir()
        local config_dir = get_jdtls_config_dir()
        local data_dir = workspace_dir

        if config.root_dir then
          data_dir = data_dir .. "/" .. vim.fn.fnamemodify(config.root_dir, ":p:h:t")
        end

        local config_cmd = {
          "jdtls",
          "--jvm-arg=-Djava.import.generatesMetadataFilesAtProjectRoot=false",
          "--jvm-arg=-Djava.autobuild.enabled=false",
          "-configuration",
          config_dir,
          -- opts.jdtls_config_dir(project_name),
          "-data",
          data_dir,
          get_jdtls_jvm_args(),
        }

        local cmd = helpers.in_shell(pkgs_list, config_cmd, opts.channel)

        return vim.lsp.rpc.start(cmd, dispatchers, {
          cwd = config.cmd_cwd,
          env = config.cmd_env,
          detached = config.detached,
          filetypes = { "java" },
          root_markers = vim.fn.has("nvim-0.11.3") == 1 and { root_markers1, root_markers2 }
            or vim.list_extend(root_markers1, root_markers2),
          settings = {
            java = {
              import = {
                generatesMetadataFilesAtProjectRoot = false,
              },
            },
          },
          init_options = {},
        })
      end,
    }
  end,
  rust_analyzer = function(pkgs_list, opts)
    local function reload_workspace(bufnr)
      local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "rust_analyzer" })
      for _, client in ipairs(clients) do
        vim.notify("Reloading Cargo Workspace")
        ---@diagnostic disable-next-line:param-type-mismatch
        client:request("rust-analyzer/reloadWorkspace", nil, function(err)
          if err then
            error(tostring(err))
          end
          vim.notify("Cargo workspace reloaded")
        end, 0)
      end
    end

    local function user_sysroot_src()
      return vim.tbl_get(vim.lsp.config["rust_analyzer"], "settings", "rust-analyzer", "cargo", "sysrootSrc")
    end

    local function default_sysroot_src()
      local sysroot = vim.tbl_get(vim.lsp.config["rust_analyzer"], "settings", "rust-analyzer", "cargo", "sysroot")
      if not sysroot then
        local rustc = os.getenv("RUSTC") or "rustc"
        local result = vim.system(helpers.in_shell(pkgs_list, { rustc, "--print", "sysroot" }, opts.channel), { text = true }):wait()

        local stdout = result.stdout
        if result.code == 0 and stdout then
          if string.sub(stdout, #stdout) == "\n" then
            if #stdout > 1 then
              sysroot = string.sub(stdout, 1, #stdout - 1)
            else
              sysroot = ""
            end
          else
            sysroot = stdout
          end
        end
      end

      return sysroot and vim.fs.joinpath(sysroot, "lib/rustlib/src/rust/library") or nil
    end

    local function is_library(fname)
      local user_home = vim.fs.normalize(vim.env.HOME)
      local cargo_home = os.getenv("CARGO_HOME") or user_home .. "/.cargo"
      local registry = cargo_home .. "/registry/src"
      local git_registry = cargo_home .. "/git/checkouts"

      local rustup_home = os.getenv("RUSTUP_HOME") or user_home .. "/.rustup"
      local toolchains = rustup_home .. "/toolchains"

      local sysroot_src = user_sysroot_src() or default_sysroot_src()

      for _, item in ipairs({ toolchains, registry, git_registry, sysroot_src }) do
        if item and vim.fs.relpath(item, fname) then
          local clients = vim.lsp.get_clients({ name = "rust_analyzer" })
          return #clients > 0 and clients[#clients].config.root_dir or nil
        end
      end
    end

    ---@type vim.lsp.Config
    return {
      cmd = helpers.in_shell(pkgs_list, { "rust-analyzer" }, opts.channel),
      filetypes = { "rust" },
      root_dir = function(bufnr, on_dir)
        local fname = vim.api.nvim_buf_get_name(bufnr)
        local reused_dir = is_library(fname)
        if reused_dir then
          on_dir(reused_dir)
          return
        end

        local cargo_crate_dir = vim.fs.root(fname, { "Cargo.toml" })
        local cargo_workspace_root

        if cargo_crate_dir == nil then
          on_dir(
            vim.fs.root(fname, { "rust-project.json" })
              or vim.fs.dirname(vim.fs.find(".git", { path = fname, upward = true })[1])
          )
          return
        end

        local cmd = {
          "cargo",
          "metadata",
          "--no-deps",
          "--format-version",
          "1",
          "--manifest-path",
          cargo_crate_dir .. "/Cargo.toml",
        }


        vim.system(helpers.in_shell(pkgs_list, cmd, opts.channel), { text = true }, function(output)
          if output.code == 0 then
            if output.stdout then
              local result = vim.json.decode(output.stdout)
              if result["workspace_root"] then
                cargo_workspace_root = vim.fs.normalize(result["workspace_root"])
              end
            end

            on_dir(cargo_workspace_root or cargo_crate_dir)
          else
            vim.schedule(function()
              vim.notify(("[rust_analyzer] cmd failed with code %d: %s\n%s"):format(output.code, cmd, output.stderr))
            end)
          end
        end)
      end,
      capabilities = {
        experimental = {
          serverStatusNotification = true,
          commands = {
            commands = {
              "rust-analyzer.showReferences",
              "rust-analyzer.runSingle",
              "rust-analyzer.debugSingle",
            },
          },
        },
      },
      ---@type lspconfig.settings.rust_analyzer
      settings = {
        ["rust-analyzer"] = {
          lens = {
            debug = { enable = true },
            enable = true,
            implementations = { enable = true },
            references = {
              adt = { enable = true },
              enumVariant = { enable = true },
              method = { enable = true },
              trait = { enable = true },
            },
            run = { enable = true },
            updateTest = { enable = true },
          },
        },
      },
      before_init = function(init_params, config)
        -- See https://github.com/rust-lang/rust-analyzer/blob/eb5da56d839ae0a9e9f50774fa3eb78eb0964550/docs/dev/lsp-extensions.md?plain=1#L26
        if config.settings and config.settings["rust-analyzer"] then
          init_params.initializationOptions = config.settings["rust-analyzer"]
        end
        ---@param command table{ title: string, command: string, arguments: any[] }
        vim.lsp.commands["rust-analyzer.runSingle"] = function(command)
          local r = command.arguments[1]
          local cmd = { "cargo", unpack(r.args.cargoArgs) }
          if r.args.executableArgs and #r.args.executableArgs > 0 then
            vim.list_extend(cmd, { "--", unpack(r.args.executableArgs) })
          end

          local proc = vim.system(helpers.in_shell(pkgs_list, cmd, opts.channel), { cwd = r.args.cwd, env = r.args.environment })

          local result = proc:wait()

          if result.code == 0 then
            vim.notify(result.stdout, vim.log.levels.INFO)
          else
            vim.notify(result.stderr, vim.log.levels.ERROR)
          end
        end
      end,
      on_attach = function(_, bufnr)
        vim.api.nvim_buf_create_user_command(bufnr, "LspCargoReload", function()
          reload_workspace(bufnr)
        end, { desc = "Reload current cargo workspace" })
      end,
    }
  end,
}
