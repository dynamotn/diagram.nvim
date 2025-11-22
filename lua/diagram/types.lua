---@class State
---@field integrations Integration[]
---@field diagrams Diagram[]

---@class PluginOptions
---@field integrations Integration[]
---@field renderer_options table<string, any>
---@field events table<string, string[]>

---@class RenderResult
---@field file_path string
---@field job_id number

---@class Renderer<table>
---@field id string
--- renders to a temp file and returns the path
---@field render fun(source: string, options?: table): RenderResult

---@class IntegrationOptions
---@field filetypes string[]
---@field renderers Renderer[]

---@class Integration
---@field id string
---@field options IntegrationOptions
---@field query_buffer_diagrams fun(bufnr?: number): Diagram[]

---@class Diagram
---@field bufnr number
---@field range { start_row: number, start_col: number, end_row: number, end_col: number }
---@field renderer_id string
---@field source string
---@field options table<string, any>|nil
---@field image Image|nil
---@field with_virtual_padding boolean|nil
---@field inline boolean|nil
