local api = vim.api
local uv = vim.uv or vim.loop ---@diagnostic disable-line: deprecated

--- @class gitsigns.main
local M = {}

local cwd_watcher ---@type uv.uv_fs_event_t?

local function log()
  return require('gitsigns.debug.log')
end

local function config()
  return require('gitsigns.config').config
end

local function async()
  return require('gitsigns.async')
end

--- @async
--- @return string? gitdir
--- @return string? head Processed head string
--- @return string? raw_head Raw output from `git rev-parse --abbrev-ref HEAD`
local function get_gitdir_and_head()
  local cwd = uv.cwd()
  if not cwd then
    return
  end

  -- Run on the main loop to avoid:
  --   https://github.com/LazyVim/LazyVim/discussions/3407#discussioncomment-9622211
  async().schedule()

  -- Look in the cache first
  if package.loaded['gitsigns.cache'] then
    for _, bcache in pairs(require('gitsigns.cache').cache) do
      local repo = bcache.git_obj.repo
      if repo.toplevel == cwd then
        -- Need raw_head from cache if possible? For now, re-parse if not found in cache quickly.
        -- If we stored RepoInfo in cache, we could use it. Let's stick to re-parsing for simplicity now.
        break -- Found repo, but might need re-parse for raw_head consistency
      end
    end
  end

  -- Get full info including raw_head
  local info = require('gitsigns.git').Repo.get_info(cwd)

  if info then
    -- Return gitdir, processed head, and raw head
    return info.gitdir, info.abbrev_head, info.raw_head
  end
  return nil, nil, nil -- Return nils if no info
end

---Sets up the cwd watcher to detect branch changes using uv.loop
---Uses module local variable cwd_watcher
---@async
---@param cwd string current working directory
---@param towatch string Directory to watch
local function setup_cwd_watcher(cwd, towatch)
  if cwd_watcher then
    cwd_watcher:stop()
    -- TODO(lewis6991): (#1027) Running `fs_event:stop()` -> `fs_event:start()`
    -- in the same loop event, on Windows, causes Nvim to hang on quit.
    if vim.fn.has('win32') == 1 then
      async().schedule()
    end
  else
    cwd_watcher = assert(uv.new_fs_event())
  end

  if cwd_watcher:getpath() == towatch then
    -- Already watching
    return
  end

  local debounce_trailing = require('gitsigns.debounce').debounce_trailing

  local update_head = debounce_trailing(100, function()
    async()
      .run(function()
        local __FUNC__ = 'update_head_callback'
        -- Fetch gitdir, processed head, and RAW head
        local gitdir, current_head, raw_head = get_gitdir_and_head()
        async().schedule()

        if not gitdir then
          log().dprint('Could not determine git directory for cwd watcher.')
          return
        end

        local old_head = vim.g.gitsigns_head -- Store the previous processed head

        -- Check if the processed head string actually changed
        if current_head ~= old_head then
          log().dprintf(
            'Head changed from "%s" to "%s" in %s',
            old_head or 'nil',
            current_head or 'nil',
            gitdir
          )
          vim.g.gitsigns_head = current_head -- Update the global variable

          -- Determine detached status based on the RAW head reference
          -- It's detached if the raw reference is exactly 'HEAD'
          local is_detached = (raw_head == 'HEAD')

          -- Trigger the GitSignsHeadChanged event with the enhanced data
          api.nvim_exec_autocmds('User', {
            pattern = 'GitSignsHeadChanged',
            modeline = false,
            data = {
              gitdir = gitdir,
              head = current_head, -- The new processed head (branch or SHA)
              old_head = old_head, -- The previous processed head
              detached = is_detached, -- Boolean flag for detached state
            },
          })

          -- Trigger the existing GitSignsUpdate event
          api.nvim_exec_autocmds('User', {
            pattern = 'GitSignsUpdate',
            modeline = false,
          })
        else
          log().dprint('Head unchanged: ', current_head or 'nil')
        end
      end)
      :raise_on_error()
  end)

  -- Watch .git/HEAD to detect branch changes
  cwd_watcher:start(towatch, {}, function(err, filename, event)
    async().run(function()
      local __FUNC__ = 'cwd_watcher_fs_event_cb'
      if err then
        log().dprintf('Git dir update error: %s', err)
        return
      end
      log().dprintf("Git HEAD update detected: '%s' %s", filename or 'nil', vim.inspect(event))

      update_head() -- Call the debounced function

      -- Re-register watcher logic (seems correct in the original code)
      -- Ensure the path 'towatch' is still valid before restarting
      if uv.fs_stat(towatch) then
        setup_cwd_watcher(cwd, towatch)
      else
        log().dprintf('Watched path %s no longer exists, stopping watcher.', towatch)
        if cwd_watcher and not cwd_watcher:is_closing() then
          cwd_watcher:close()
          cwd_watcher = nil
        end
      end
    end)
  end)
end

--- @async
local function update_cwd_head()
  local cwd = uv.cwd()
  if not cwd then
    log().dprint('Could not get current working directory.')
    return
  end

  -- Find .git directory (existing logic is fine)
  local paths = vim.fs.find('.git', {
    limit = 1,
    upward = true,
    type = 'directory',
  })

  if #paths == 0 then
    log().dprint('No .git directory found upwards from CWD.')
    -- Clear potentially stale global head if we're no longer in a git repo
    if vim.g.gitsigns_head ~= nil then
      vim.g.gitsigns_head = nil
      api.nvim_exec_autocmds('User', { pattern = 'GitSignsUpdate', modeline = false })
    end
    -- Stop watcher if it was running for a previous git dir
    if cwd_watcher and not cwd_watcher:is_closing() then
      cwd_watcher:close()
      cwd_watcher = nil
      log().dprint('Stopped CWD watcher.')
    end
    return -- Not in a git repo
  end

  -- Get initial state including gitdir, processed head, and raw head
  local gitdir, head, raw_head = get_gitdir_and_head()
  async().schedule() -- Ensure we run on the main loop

  -- Check if we successfully got the repository info
  if not gitdir then
    log().dprint('Initial CWD head/gitdir determination failed (post .git check).')
    return
  end

  -- Determine initial detached state
  local is_detached = (raw_head == 'HEAD')

  -- *** Fire the initial GitSignsHeadChanged event ***
  -- Trigger this *before* setting vim.g.gitsigns_head so the comparison
  -- logic in the watcher's update_head doesn't rely on potentially stale state
  -- if this function runs multiple times quickly (though unlikely with DirChanged debounce).
  log().dprint('Firing initial GitSignsHeadChanged event for CWD.')
  api.nvim_exec_autocmds('User', {
    pattern = 'GitSignsHeadChanged',
    modeline = false,
    data = {
      gitdir = gitdir,
      head = head,
      init = true,
      old_head = nil, -- Explicitly nil for the initial event
      detached = is_detached,
    },
  })

  -- Set initial global state (used by watcher callback comparison and statuslines)
  -- Do this *after* firing the initial event with old_head = nil
  vim.g.gitsigns_head = head

  -- Trigger general update (e.g., for statuslines that use GitSignsUpdate)
  api.nvim_exec_autocmds('User', {
    pattern = 'GitSignsUpdate',
    modeline = false,
  })

  -- Setup the watcher for subsequent changes
  local towatch = gitdir .. '/HEAD'
  -- Check if .git/HEAD exists before attempting to watch it
  if not uv.fs_stat(towatch) then
    log().dprintf('Cannot watch %s, file does not exist (likely initial commit needed).', towatch)
    -- Stop watcher if it was watching something else
    if cwd_watcher and not cwd_watcher:is_closing() then
      cwd_watcher:close()
      cwd_watcher = nil
      log().dprint('Stopped CWD watcher as HEAD file missing.')
    end
    return
  end
  -- Pass CWD and path to watch to the setup function
  setup_cwd_watcher(cwd, towatch)
end

local function setup_cli()
  api.nvim_create_user_command('Gitsigns', function(params)
    require('gitsigns.cli').run(params)
  end, {
    force = true,
    nargs = '*',
    range = true,
    complete = function(arglead, line)
      return require('gitsigns.cli').complete(arglead, line)
    end,
  })
end

local function setup_attach()
  local attach_autocmd_disabled = false

  -- Need to attach in 'BufFilePost' since we always detach in 'BufFilePre'
  api.nvim_create_autocmd({ 'BufFilePost', 'BufRead', 'BufNewFile', 'BufWritePost' }, {
    group = 'gitsigns',
    desc = 'Gitsigns: attach',
    callback = function(args)
      if not config().auto_attach then
        return
      end
      local bufnr = args.buf
      if attach_autocmd_disabled then
        local __FUNC__ = 'attach_autocmd'
        log().dprint('Attaching is disabled')
        return
      end
      require('gitsigns.actions').attach(bufnr, nil, args.event)
    end,
  })

  --- vimpgrep creates and deletes lots of buffers so attaching to each one will
  --- waste lots of resource and slow down vimgrep.
  api.nvim_create_autocmd({ 'QuickFixCmdPre', 'QuickFixCmdPost' }, {
    group = 'gitsigns',
    pattern = '*vimgrep*',
    desc = 'Gitsigns: disable attach during vimgrep',
    callback = function(args)
      attach_autocmd_disabled = args.event == 'QuickFixCmdPre'
    end,
  })

  -- Attach to all open buffers
  if config().auto_attach then
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(buf) and api.nvim_buf_get_name(buf) ~= '' then
        -- Make sure to run each attach in its on async context in case one of the
        -- attaches is aborted.
        require('gitsigns.actions').attach(buf, nil, 'setup')
      end
    end
  end
end

local function setup_cwd_head()
  local debounce_trailing = require('gitsigns.debounce').debounce_trailing
  local update_cwd_head_debounced = debounce_trailing(100, function()
    async().run(update_cwd_head):raise_on_error()
  end)

  update_cwd_head_debounced()

  -- Need to debounce in case some plugin changes the cwd too often
  -- (like vim-grepper)
  api.nvim_create_autocmd('DirChanged', {
    group = 'gitsigns',
    callback = function()
      update_cwd_head_debounced()
    end,
  })
end

-- When setup() is called when this is true, setup autocmads and define
-- highlights. If false then rebuild the configuration and re-setup
-- modules that depend on the configuration.
local init = true

--- Setup and start Gitsigns.
---
--- @param cfg table|nil Configuration for Gitsigns.
---     See |gitsigns-usage| for more details.
function M.setup(cfg)
  if vim.fn.executable('git') == 0 then
    print('gitsigns: git not in path. Aborting setup')
    return
  end

  if cfg then
    require('gitsigns.config').build(cfg)
  end

  -- Only do this once
  if init then
    api.nvim_create_augroup('gitsigns', {})
    setup_cli()
    -- TODO(lewis6991): do this lazily
    require('gitsigns.highlight').setup()
    setup_attach()
    setup_cwd_head()

    init = false
  end
end

--- @type gitsigns.main|gitsigns.actions|gitsigns.attach|gitsigns.debug
M = setmetatable(M, {
  __index = function(_, f)
    local actions = require('gitsigns.actions')
    if actions[f] then
      return actions[f]
    end

    if config().debug_mode then
      local debug = require('gitsigns.debug')
      if debug[f] then
        return debug[f]
      end
    end
  end,
})

return M