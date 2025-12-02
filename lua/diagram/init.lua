local hover = require('diagram/hover')
local integrations = require('diagram/integrations')

---@class State
local state = {
  events = {
    render_buffer = { 'InsertLeave', 'BufWinEnter', 'TextChanged' },
    clear_buffer = { 'BufLeave' },
  },
  renderer_options = {
    mermaid = {
      background = nil,
      theme = nil,
      scale = nil,
      width = nil,
      height = nil,
      cli_args = nil,
    },
    plantuml = {
      charset = nil,
      cli_args = nil,
    },
    d2 = {
      theme_id = nil,
      dark_theme_id = nil,
      scale = nil,
      layout = nil,
      sketch = nil,
      cli_args = nil,
    },
    gnuplot = {
      size = nil,
      font = nil,
      theme = nil,
      cli_args = nil,
    },
  },
  integrations = {
    integrations.markdown,
    integrations.neorg,
  },
  diagrams = {},
  render_timers = {},
}

local clear_buffer = function(bufnr)
  local i = 1
  while i <= #state.diagrams do
    local diagram = state.diagrams[i]
    if diagram.bufnr == bufnr then
      if diagram.image ~= nil then
        diagram.image:clear()
      end
      table.remove(state.diagrams, i)
    else
      i = i + 1
    end
  end
end

---@param bufnr number
---@param winnr number
---@param integration Integration
local render_buffer = function(bufnr, winnr, integration)
  local diagrams = integration.query_buffer_diagrams(bufnr)
  clear_buffer(bufnr)
  
  -- Limit max diagrams per buffer to prevent memory leaks
  local max_diagrams_per_buffer = 50
  local buffer_diagram_count = #diagrams
  if buffer_diagram_count > max_diagrams_per_buffer then
    vim.notify(
      'Diagram.nvim: Buffer has ' .. buffer_diagram_count .. ' diagrams (max: ' .. max_diagrams_per_buffer .. '). Some diagrams will not be rendered.',
      vim.log.levels.WARN,
      { title = 'Diagram.nvim' }
    )
    for i = max_diagrams_per_buffer + 1, buffer_diagram_count do
      diagrams[i] = nil
    end
  end
  
  for _, diagram in ipairs(diagrams) do
    ---@type Renderer
    local renderer = nil
    for _, r in ipairs(integration.renderers) do
      if r.id == diagram.renderer_id then
        renderer = r
        break
      end
    end
    if not renderer then
      vim.notify(
        'Unknown diagram renderer: ' .. diagram.renderer_id,
        vim.log.levels.ERROR,
        { title = 'Diagram.nvim' }
      )
      goto continue
    end

    -- Merge global options with per-diagram options (per-diagram takes precedence)
    local global_options = state.renderer_options[renderer.id] or {}
    local merged_options =
      vim.tbl_deep_extend('force', global_options, diagram.options or {})
    local renderer_result = renderer.render(diagram.source, merged_options)

    -- Skip rendering if the renderer returned nil (e.g., executable not found)
    if not renderer_result then goto continue end

    local function render_image()
      -- Check if buffer still exists
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      if vim.fn.filereadable(renderer_result.file_path) == 0 then return end

      local image_nvim = require('image')
      local image = image_nvim.from_file(renderer_result.file_path, {
        buffer = bufnr,
        window = winnr,
        with_virtual_padding = diagram.with_virtual_padding == nil and true
          or diagram.with_virtual_padding,
        inline = diagram.inline == nil and true or diagram.inline,
        x = diagram.range.start_col,
        y = diagram.range.start_row,
        width = math.abs(diagram.range.end_col - diagram.range.start_col),
        height = math.abs(diagram.range.end_row - diagram.range.start_row),
        render_offset_top = 1,
      })
      diagram.image = image

      table.insert(state.diagrams, diagram)
      if image then image:render() end
    end

    if renderer_result.job_id then
      -- Use a timer to poll the job's completion status every 100ms.
      local timer = vim.loop.new_timer()
      if not timer then return end
      timer:start(
        0,
        100,
        vim.schedule_wrap(function()
          local result = vim.fn.jobwait({ renderer_result.job_id }, 0)
          if result[1] ~= -1 then
            if timer:is_active() then timer:stop() end
            if not timer:is_closing() then
              timer:close()
              render_image()
            end
          end
        end)
      )
    else
      render_image()
    end

    ::continue::
  end
end

---@param opts PluginOptions
local setup = function(opts)
  local ok = pcall(require, 'image')
  if not ok then
    vim.notify(
      'Missing dependency: 3rd/image.nvim\nPlease install image.nvim to use diagram.nvim',
      vim.log.levels.ERROR,
      { title = 'Diagram.nvim' }
    )
    return
  end

  state.integrations = opts.integrations or state.integrations
  state.events = vim.tbl_deep_extend('force', state.events, opts.events or {})
  state.renderer_options = vim.tbl_deep_extend(
    'force',
    state.renderer_options,
    opts.renderer_options or {}
  )
  state.events = vim.tbl_deep_extend('force', state.events, opts.events or {})

  local current_bufnr = vim.api.nvim_get_current_buf()
  local current_winnr = vim.api.nvim_get_current_win()
  local current_ft = vim.bo[current_bufnr].filetype

  local setup_buffer = function(bufnr, integration)
    -- render (only if events are configured)
    if not state.events.render_buffer or #state.events.render_buffer == 0 then
      return
    end

    local render_with_debounce = function()
      -- Cancel previous timer if exists
      if state.render_timers[bufnr] then
        state.render_timers[bufnr]:stop()
        state.render_timers[bufnr]:close()
        state.render_timers[bufnr] = nil
      end

      -- Create new timer with 500ms debounce for TextChanged events
      local timer = vim.loop.new_timer()
      if not timer then return end
      
      state.render_timers[bufnr] = timer
      timer:start(
        500,
        0,
        vim.schedule_wrap(function()
          state.render_timers[bufnr] = nil
          local winnr = vim.api.nvim_get_current_win()
          render_buffer(bufnr, winnr, integration)
        end)
      )
    end

    for _, event in ipairs(state.events.render_buffer) do
      if event == 'TextChanged' or event == 'TextChangedI' then
        vim.api.nvim_create_autocmd(event, {
          buffer = bufnr,
          callback = render_with_debounce,
        })
      else
        vim.api.nvim_create_autocmd(event, {
          buffer = bufnr,
          callback = function(_)
            -- Cancel any pending timer for immediate events
            if state.render_timers[bufnr] then
              state.render_timers[bufnr]:stop()
              state.render_timers[bufnr]:close()
              state.render_timers[bufnr] = nil
            end
            local winnr = vim.api.nvim_get_current_win()
            render_buffer(bufnr, winnr, integration)
          end,
        })
      end
    end

    -- clear
    if state.events.clear_buffer then
      vim.api.nvim_create_autocmd(state.events.clear_buffer, {
        buffer = bufnr,
        callback = function() clear_buffer(bufnr) end,
      })
    end
    
    -- Also clear when buffer is deleted to prevent memory leak
    vim.api.nvim_create_autocmd('BufDelete', {
      buffer = bufnr,
      callback = function() clear_buffer(bufnr) end,
    })
  end

  -- setup integrations
  for _, integration in ipairs(state.integrations) do
    vim.api.nvim_create_autocmd('FileType', {
      pattern = integration.filetypes,
      callback = function(ft_event) setup_buffer(ft_event.buf, integration) end,
    })

    -- first render (only if render events are enabled)
    if
      vim.tbl_contains(integration.filetypes, current_ft)
      and state.events.render_buffer
      and #state.events.render_buffer > 0
    then
      setup_buffer(current_bufnr, integration)
      render_buffer(current_bufnr, current_winnr, integration)
    elseif vim.tbl_contains(integration.filetypes, current_ft) then
      -- Still setup buffer for potential hover usage but don't auto-render
      setup_buffer(current_bufnr, integration)
    end
  end
end

local get_cache_dir = function()
  return vim.fn.stdpath('cache') .. '/diagram-cache'
end

local show_diagram_hover = function()
  hover.hover_at_cursor(state.integrations, state.renderer_options)
end

return {
  setup = setup,
  get_cache_dir = get_cache_dir,
  show_diagram_hover = show_diagram_hover,
}
