local Buffer = require("neogit.lib.buffer")
local GitCommandHistory = require("neogit.buffers.git_command_history")
local CommitView = require("neogit.buffers.commit_view")
local git = require("neogit.lib.git")
local notification = require("neogit.lib.notification")
local config = require("neogit.config")
local a = require("plenary.async")
local logger = require("neogit.logger")
local Collection = require("neogit.lib.collection")
local F = require("neogit.lib.functional")
local LineBuffer = require("neogit.lib.line_buffer")
local fs = require("neogit.lib.fs")
local input = require("neogit.lib.input")
local util = require("neogit.lib.util")
local watcher = require("neogit.watcher")
local operation = require("neogit.operations")

local api = vim.api
local fn = vim.fn

--- Map from git root to status buffers
---@type table<string, StatusBuffer>
local status_buffers = {}

---@class StatusBuffer
---@field disabled boolean
---@field prev_autochdir string
---@field buffer Buffer
---@field commit_view any
---@field watcher Watcher
---@field cwd string
---@field old_cwd string
---@field cursor_location any
---
---@field locations Section[]
---@field outdated any
local M = {}
M.__index = M

---@class Section
---@field first number
---@field last number
---@field items StatusItem[]
---@field name string
---@field ignore_sign boolean If true will skip drawing the section icons
---@field folded boolean|nil

---@class StatusItem
---@field name string
---@field first number
---@field last number
---@field oid string|nil optional object id
---@field commit CommitLogEntry|nil optional object id
---@field folded boolean|nil
---@field hunks Hunk[]|nil
---@field diff Diff|nil

local head_start = "@"
local add_start = "+"
local del_start = "-"

---@param self StatusBuffer
---@param linenr number
local function get_section_idx_for_line(self, linenr)
  for i, l in pairs(self.locations) do
    if l.first <= linenr and linenr <= l.last then
      return i
    end
  end
  return nil
end

---@param self StatusBuffer
---@param linenr number
local function get_section_item_idx_for_line(self, linenr)
  local section_idx = get_section_idx_for_line(self, linenr)
  local section = self.locations[section_idx]

  if section == nil then
    return nil, nil
  end

  for i, item in pairs(section.items) do
    if item.first <= linenr and linenr <= item.last then
      return section_idx, i
    end
  end

  return section_idx, nil
end

---@param self StatusBuffer
---@param linenr number
---@return Section|nil, StatusItem|nil
local function get_section_item_for_line(self, linenr)
  local section_idx, item_idx = get_section_item_idx_for_line(self, linenr)
  local section = self.locations[section_idx]

  if section == nil then
    return nil, nil
  end
  if item_idx == nil then
    return section, nil
  end

  return section, section.items[item_idx]
end

---@param self StatusBuffer
---@return Section|nil, StatusItem|nil
function M:get_current_section_item()
  return get_section_item_for_line(self, vim.fn.line("."))
end

local mode_to_text = {
  M = "Modified",
  N = "New file",
  A = "Added",
  D = "Deleted",
  C = "Copied",
  U = "Updated",
  UU = "Both Modified",
  R = "Renamed",
}

local max_len = #"Modified by us"

function M:draw_sign_for_item(item, name)
  if item.folded then
    self.buffer:place_sign(item.first, "NeogitClosed:" .. name, "fold_markers")
  else
    self.buffer:place_sign(item.first, "NeogitOpen:" .. name, "fold_markers")
  end
end

function M:draw_signs()
  if config.values.disable_signs then
    return
  end
  for _, l in ipairs(self.locations) do
    if not l.ignore_sign then
      self:draw_sign_for_item(l, "section")
      if not l.folded then
        Collection.new(l.items):filter(F.dot("hunks")):each(function(f)
          self:draw_sign_for_item(f, "item")
          if not f.folded then
            Collection.new(f.hunks):each(function(h)
              self:draw_sign_for_item(h, "hunk")
            end)
          end
        end)
      end
    end
  end
end

local function format_submodule_mode(mode)
  local res = {}

  if mode.commit_changed then
    table.insert(res, "new commits")
  end

  if mode.has_tracked_changes then
    table.insert(res, "modfied content")
  end

  if mode.has_untracked_changes then
    table.insert(res, "untracked content")
  end

  return #res > 0 and "(" .. table.concat(res, ", ") .. ")" or "(malformed submodule)"
end

local function format_mode(mode)
  if not mode then
    return ""
  end
  local res = mode_to_text[mode]
  if res then
    return res
  end

  local res = mode_to_text[mode:sub(1, 1)]
  if res then
    return res .. " by us"
  end

  return mode
end

function M:draw_buffer()
  self.buffer:clear_sign_group("hl")
  self.buffer:clear_sign_group("fold_markers")

  local output = LineBuffer.new()
  if not config.values.disable_hint then
    local reversed_status_map = config.get_reversed_status_maps()
    local reversed_popup_map = config.get_reversed_popup_maps()

    local function hint_label(map_name, hint)
      local keys = reversed_status_map[map_name] or reversed_popup_map[map_name]
      if keys and #keys > 0 then
        return string.format("[%s] %s", table.concat(keys, " "), hint)
      else
        return string.format("[<unmapped>] %s", hint)
      end
    end

    local hints = {
      hint_label("Toggle", "toggle diff"),
      hint_label("Stage", "stage"),
      hint_label("Unstage", "unstage"),
      hint_label("Discard", "discard"),
      hint_label("CommitPopup", "commit"),
      hint_label("HelpPopup", "help"),
    }

    output:append("Hint: " .. table.concat(hints, " | "))
    output:append("")
  end

  local new_locations = {}
  local locations_lookup = Collection.new(self.locations):key_by("name")

  output:append(
    string.format(
      "Head:     %s%s %s",
      (git.repo.head.abbrev and git.repo.head.abbrev .. " ") or "",
      git.repo.head.branch,
      git.repo.head.commit_message or "(no commits)"
    )
  )

  table.insert(new_locations, {
    name = "head_branch_header",
    first = #output,
    last = #output,
    items = {},
    ignore_sign = true,
    commit = { oid = git.repo.head.oid },
  })

  if not git.branch.is_detached() then
    if git.repo.upstream.ref then
      output:append(
        string.format(
          "Merge:    %s%s %s",
          (git.repo.upstream.abbrev and git.repo.upstream.abbrev .. " ") or "",
          git.repo.upstream.ref,
          git.repo.upstream.commit_message or "(no commits)"
        )
      )

      table.insert(new_locations, {
        name = "upstream_header",
        first = #output,
        last = #output,
        items = {},
        ignore_sign = true,
        commit = { oid = git.repo.upstream.oid },
      })
    end

    if git.branch.pushRemote_ref() and git.repo.pushRemote.abbrev then
      output:append(
        string.format(
          "Push:     %s%s %s",
          (git.repo.pushRemote.abbrev and git.repo.pushRemote.abbrev .. " ") or "",
          git.branch.pushRemote_ref(),
          git.repo.pushRemote.commit_message or "(does not exist)"
        )
      )

      table.insert(new_locations, {
        name = "push_branch_header",
        first = #output,
        last = #output,
        items = {},
        ignore_sign = true,
        ref = git.branch.pushRemote_ref(),
      })
    end
  end

  if git.repo.head.tag.name then
    output:append(string.format("Tag:      %s (%s)", git.repo.head.tag.name, git.repo.head.tag.distance))
    table.insert(new_locations, {
      name = "tag_header",
      first = #output,
      last = #output,
      items = {},
      ignore_sign = true,
      commit = { oid = git.rev_parse.oid(git.repo.head.tag.name) },
    })
  end

  output:append("")

  function M:render_section(header, key, data)
    local section_config = config.values.sections[key]
    if section_config.hidden then
      return
    end

    data = data or git.repo[key]
    if #data.items == 0 then
      return
    end

    if data.current then
      output:append(string.format("%s (%d/%d)", header, data.current, #data.items))
    else
      output:append(string.format("%s (%d)", header, #data.items))
    end

    local location = locations_lookup[key]
      or {
        name = key,
        folded = section_config.folded,
        items = {},
      }
    location.first = #output

    if not location.folded then
      local items_lookup = Collection.new(location.items):key_by("name")
      location.items = {}

      for _, f in ipairs(data.items) do
        local label = util.pad_right(format_mode(f.mode), max_len)

        if label and vim.o.columns < 120 then
          label = vim.trim(label)
        end

        local line
        if f.mode and f.original_name then
          line = string.format("%s %s -> %s", label, f.original_name, f.name)
        elseif f.mode then
          line = string.format("%s %s", label, f.name)
        else
          line = f.name
        end

        if f.submodule then
          line = line .. " " .. format_submodule_mode(f.submodule)
        end

        output:append(line)

        if f.done then
          self.buffer:place_sign(#output, "NeogitRebaseDone", "hl")
        end

        local file = items_lookup[f.name] or { folded = true }
        file.first = #output

        if not file.folded and f.has_diff then
          local hunks_lookup = Collection.new(file.hunks or {}):key_by("hash")

          local hunks = {}
          for _, h in ipairs(f.diff.hunks) do
            local current_hunk = hunks_lookup[h.hash] or { folded = false }

            output:append(f.diff.lines[h.diff_from])
            current_hunk.first = #output

            if not current_hunk.folded then
              for i = h.diff_from + 1, h.diff_to do
                output:append(f.diff.lines[i])
              end
            end

            current_hunk.last = #output
            table.insert(hunks, setmetatable(current_hunk, { __index = h }))
          end

          file.hunks = hunks
        elseif f.has_diff then
          file.hunks = file.hunks or {}
        end

        file.last = #output
        table.insert(location.items, setmetatable(file, { __index = f }))
      end
    end

    location.last = #output

    if not location.folded then
      output:append("")
    end

    table.insert(new_locations, location)
  end

  if git.repo.rebase.head then
    self:render_section("Rebasing: " .. git.repo.rebase.head, "rebase")
  elseif git.repo.sequencer.head == "REVERT_HEAD" then
    self:render_section("Reverting", "sequencer")
  elseif git.repo.sequencer.head == "CHERRY_PICK_HEAD" then
    self:render_section("Picking", "sequencer")
  end

  self:render_section("Untracked files", "untracked")
  self:render_section("Unstaged changes", "unstaged")
  self:render_section("Staged changes", "staged")
  self:render_section("Stashes", "stashes")

  local pushRemote = git.branch.pushRemote_ref()
  local upstream = git.branch.upstream()

  if pushRemote and upstream ~= pushRemote then
    self:render_section(
      string.format("Unpulled from %s", pushRemote),
      "unpulled_pushRemote",
      git.repo.pushRemote.unpulled
    )
    self:render_section(
      string.format("Unpushed to %s", pushRemote),
      "unmerged_pushRemote",
      git.repo.pushRemote.unmerged
    )
  end

  if upstream then
    self:render_section(
      string.format("Unpulled from %s", upstream),
      "unpulled_upstream",
      git.repo.upstream.unpulled
    )
    self:render_section(
      string.format("Unmerged into %s", upstream),
      "unmerged_upstream",
      git.repo.upstream.unmerged
    )
  end

  self:render_section("Recent commits", "recent")

  self.buffer:replace_content_with(output)
  self.locations = new_locations
end

--- Find the smallest section the cursor is contained within.
--
--  The first 3 values are tables in the shape of {number, string}, where the number is
--  the relative offset of the found item and the string is it's identifier.
--  The remaining 2 numbers are the first and last line of the found section.
---@param linenr number|nil
---@return table, table, table, number, number
function M:save_cursor_location(linenr)
  local line = linenr or vim.api.nvim_win_get_cursor(0)[1]
  local section_loc, file_loc, hunk_loc, first, last

  for li, loc in ipairs(self.locations) do
    if line == loc.first then
      section_loc = { li, loc.name }
      first, last = loc.first, loc.last

      break
    elseif line >= loc.first and line <= loc.last then
      section_loc = { li, loc.name }

      for fi, file in ipairs(loc.items) do
        if line == file.first then
          file_loc = { fi, file.name }
          first, last = file.first, file.last

          break
        elseif line >= file.first and line <= file.last then
          file_loc = { fi, file.name }

          for hi, hunk in ipairs(file.hunks) do
            if line >= hunk.first and line <= hunk.last then
              hunk_loc = { hi, hunk.hash }
              first, last = hunk.first, hunk.last

              break
            end
          end

          break
        end
      end

      break
    end
  end

  return section_loc, file_loc, hunk_loc, first, last
end

function M:restore_cursor_location(section_loc, file_loc, hunk_loc)
  if #self.locations == 0 then
    return vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end

  if not section_loc then
    -- Skip the headers and put the cursor on the first foldable region
    local idx = 1
    for i, location in ipairs(self.locations) do
      if not location.ignore_sign then
        idx = i
        break
      end
    end
    section_loc = { idx, "" }
  end

  local section = Collection.new(self.locations):find(function(s)
    return s.name == section_loc[2]
  end)

  if not section then
    file_loc, hunk_loc = nil, nil
    section = self.locations[section_loc[1]] or self.locations[#self.locations]
  end

  if not file_loc or not section.items or #section.items == 0 then
    return vim.api.nvim_win_set_cursor(0, { section.first, 0 })
  end

  local file = Collection.new(section.items):find(function(f)
    return f.name == file_loc[2]
  end)

  if not file then
    hunk_loc = nil
    file = section.items[file_loc[1]] or section.items[#section.items]
  end

  if not hunk_loc or not file.hunks or #file.hunks == 0 then
    return vim.api.nvim_win_set_cursor(0, { file.first, 0 })
  end

  local hunk = Collection.new(file.hunks):find(function(h)
    return h.hash == hunk_loc[2]
  end) or file.hunks[hunk_loc[1]] or file.hunks[#file.hunks]

  return vim.api.nvim_win_set_cursor(0, { hunk.first, 0 })
end

function M:refresh_status_buffer()
  if self.buffer == nil then
    return
  end

  self.buffer:unlock()

  logger.debug("[STATUS BUFFER]: Redrawing")

  self:draw_buffer()
  self:draw_signs()

  logger.debug("[STATUS BUFFER]: Finished Redrawing")

  self.buffer:lock()

  vim.cmd("redraw")
end

local refresh_lock = a.control.Semaphore.new(1)

function M.is_refresh_locked()
  return refresh_lock.permits == 0
end

local function get_refresh_lock(reason)
  local permit = refresh_lock:acquire()
  logger.debug(("[STATUS BUFFER]: Acquired refresh lock:"):format(reason or "unknown"))

  vim.defer_fn(function()
    if M.is_refresh_locked() then
      permit:forget()
      logger.debug(
        ("[STATUS BUFFER]: Refresh lock for %s expired after 10 seconds"):format(reason or "unknown")
      )
    end
  end, 10000)

  return permit
end

function M:refresh(partial, reason)
  local permit = get_refresh_lock(reason)
  local callback = function()
    local s, f, h = self:save_cursor_location()
    self:refresh_status_buffer()

    if self.buffer ~= nil and self.buffer:is_focused() then
      pcall(self.restore_cursor_location, self, s, f, h)
    end

    vim.api.nvim_exec_autocmds("User", { pattern = "NeogitStatusRefreshed", modeline = false })

    permit:forget()
    logger.info("[STATUS BUFFER]: Refresh lock is now free")
  end

  git.repo:refresh { source = reason, callback = callback, partial = partial }
end

---@param which table|boolean|nil
---@param reason string|nil
function M:dispatch_refresh(which, reason)
  a.void(function()
    reason = reason or "unknown"
    if M.is_refresh_locked() then
      logger.debug("[STATUS] Refresh lock is active. Skipping refresh from " .. reason)
    else
      self:refresh(which, reason)
    end
  end)()
end

function M:refresh_manually(fname)
  a.void(function()
    if not fname or fname == "" then
      return
    end

    local path = fs.relpath_from_repository(fname)
    if not path then
      return
    end
    if refresh_lock.permits > 0 then
      self:refresh({ update_diffs = { "*:" .. path } }, "manually")
    end
  end)
end

--- Compatibility endpoint to refresh data from an autocommand.
--  `fname` should be `<afile>` in this case. This function will take care of
--  resolving the file name to the path relative to the repository root and
--  refresh that file's cache data.
function M:refresh_viml_compat(fname)
  logger.info("[STATUS BUFFER]: refresh_viml_compat")
  if not config.values.auto_refresh then
    return
  end
  if #vim.fs.find(".git/", { upward = true }) == 0 then -- not a git repository
    return
  end

  self:refresh_manually(fname)
end

function M:current_line_is_hunk()
  local _, _, h = self:save_cursor_location()
  return h ~= nil
end

function M:toggle()
  local selection = self:get_selection()
  if selection.section == nil then
    return
  end

  local item = selection.item

  local hunks = item and M.get_item_hunks(item, selection.first_line, selection.last_line, false)
  if item and hunks and #hunks > 0 then
    for _, hunk in ipairs(hunks) do
      hunk.hunk.folded = not hunk.hunk.folded
    end

    vim.api.nvim_win_set_cursor(0, { hunks[1].first, 0 })
  elseif item then
    item.folded = not item.folded
  elseif selection.section ~= nil then
    selection.section.folded = not selection.section.folded
  end

  self:refresh_status_buffer()
end

function M:reset()
  git.repo:reset()
  self.locations = {}
  if not config.values.auto_refresh then
    return
  end
  self:refresh(nil, "reset")
end

function M:dispatch_reset()
  a.void(function()
    M:reset()
  end)
end

function M.reset_all()
  print("resetting all status buffers")
  for k, status_buffer in pairs(status_buffers) do
    print("resetting status buffer", k)
    status_buffer:reset()
  end
end

function M.refresh_all(which, reason)
  logger.fmt_info("[STATUS BUFFER]: Refreshing all status buffers")
  for name, status_buffer in pairs(status_buffers) do
    logger.fmt_info("[STATUS BUFFER]: Refreshing status buffer %s", name)
    status_buffer:refresh(which, reason)
  end
end

M.dispatch_reset_all = a.void(M.reset_all)
M.dispatch_refresh_all = a.void(M.refresh_all)

function M.dispatch_refresh_manually_all()
  for _, status_buffer in pairs(status_buffers) do
    status_buffer:refresh_manually()
  end
end

function M:close(skip_close)
  if self.closing then
    return
  end

  self.closing = true

  status_buffers[self.cwd] = nil

  if skip_close == nil then
    skip_close = false
  end

  M.cursor_location = { self:save_cursor_location() }

  if not skip_close then
    self.buffer:close()
  end

  if self.watcher then
    self.watcher:stop()
  end
  notification.delete_all()
  vim.o.autochdir = self.prev_autochdir
  if self.old_cwd then
    vim.cmd.lcd(self.old_cwd)
  end
end

function M.close_all(skip_close)
  for _, status_buffer in pairs(status_buffers) do
    status_buffer:close(skip_close)
  end
end

---@class Selection
---@field sections SectionSelection[]
---@field first_line number
---@field last_line number
---Current items under the cursor
---@field section Section|nil
---@field item StatusItem|nil
---@field commit CommitLogEntry|nil
---
---@field commits  CommitLogEntry[]
---@field items  StatusItem[]
local Selection = {}
Selection.__index = Selection

---@class SectionSelection: Section
---@field section Section
---@field name string
---@field items StatusItem[]

---@return string[], string[]

function Selection:format()
  local lines = {}

  table.insert(lines, string.format("%d,%d:", self.first_line, self.last_line))

  for _, sec in ipairs(self.sections) do
    table.insert(lines, string.format("%s:", sec.name))
    for _, item in ipairs(sec.items) do
      table.insert(lines, string.format("  %s%s:", item == self.item and "*" or "", item.name))
      for _, hunk in ipairs(M.get_item_hunks(item, self.first_line, self.last_line, true)) do
        table.insert(lines, string.format("    %d,%d:", hunk.from, hunk.to))
        for _, line in ipairs(hunk.lines) do
          table.insert(lines, string.format("      %s", line))
        end
      end
    end
  end

  return table.concat(lines, "\n")
end

---@class SelectedHunk: Hunk
---@field from number start offset from the first line of the hunk
---@field to number end offset from the first line of the hunk
---@field lines string[]

---@param item StatusItem
---@param first_line number
---@param last_line number
---@param partial boolean
---@return SelectedHunk[]
function M.get_item_hunks(item, first_line, last_line, partial)
  local hunks = {}

  if not item.folded and item.hunks then
    for _, h in ipairs(item.hunks) do
      if h.first <= last_line and h.last >= first_line then
        local from, to

        if partial then
          local cursor_offset = first_line - h.first
          local length = last_line - first_line

          from = h.diff_from + cursor_offset
          to = from + length
        else
          from = h.diff_from + 1
          to = h.diff_to
        end

        local hunk_lines = {}
        for i = from, to do
          table.insert(hunk_lines, item.diff.lines[i])
        end

        local o = {
          from = from,
          to = to,
          __index = h,
          hunk = h,
          lines = hunk_lines,
        }

        setmetatable(o, o)

        table.insert(hunks, o)
      end
    end
  end

  return hunks
end

---@param selection Selection
function M.selection_hunks(selection)
  local res = {}
  for _, item in ipairs(selection.items) do
    local lines = {}
    local hunks = {}

    for _, h in ipairs(selection.item.hunks) do
      if h.first <= selection.last_line and h.last >= selection.first_line then
        table.insert(hunks, h)
        for i = h.diff_from, h.diff_to do
          table.insert(lines, item.diff.lines[i])
        end
        break
      end
    end

    table.insert(res, {
      item = item,
      hunks = hunks,
      lines = lines,
    })
  end

  return res
end

---Returns the selected items grouped by spanned sections
---@return Selection
function M:get_selection()
  local visual_pos = vim.fn.getpos("v")[2]
  local cursor_pos = vim.fn.getpos(".")[2]

  local first_line = math.min(visual_pos, cursor_pos)
  local last_line = math.max(visual_pos, cursor_pos)

  local res = {
    sections = {},
    first_line = first_line,
    last_line = last_line,
    item = nil,
    commit = nil,
    commits = {},
    items = {},
  }

  for _, section in ipairs(self.locations) do
    local items = {}

    if section.first > last_line then
      break
    end

    if section.last >= first_line then
      if section.first <= first_line and section.last >= last_line then
        res.section = section
      end

      local entire_section = section.first == first_line and first_line == last_line

      for _, item in pairs(section.items) do
        if entire_section or item.first <= last_line and item.last >= first_line then
          if not res.item and item.first <= first_line and item.last >= last_line then
            res.item = item

            res.commit = item.commit
          end

          if item.commit then
            table.insert(res.commits, item.commit)
          end

          table.insert(res.items, item)
          table.insert(items, item)
        end
      end

      local section = {
        section = section,
        items = items,
        __index = section,
      }

      setmetatable(section, section)
      table.insert(res.sections, section)
    end
  end

  return setmetatable(res, Selection)
end

function M:stage()
  return operation("stage", function()
    local selection = self:get_selection()
    local mode = vim.api.nvim_get_mode()

    local files = {}

    for _, section in ipairs(selection.sections) do
      for _, item in ipairs(section.items) do
        local hunks = M.get_item_hunks(item, selection.first_line, selection.last_line, mode.mode == "V")

        if section.name == "unstaged" then
          if #hunks > 0 then
            for _, hunk in ipairs(hunks) do
              -- Apply works for both tracked and untracked
              local patch = git.index.generate_patch(item, hunk, hunk.from, hunk.to)
              git.index.apply(patch, { cached = true })
            end
          else
            git.status.stage { item.name }
          end
        elseif section.name == "untracked" then
          if #hunks > 0 then
            for _, hunk in ipairs(hunks) do
              -- Apply works for both tracked and untracked
              git.index.apply(git.index.generate_patch(item, hunk, hunk.from, hunk.to), { cached = true })
            end
          else
            table.insert(files, item.name)
          end
        else
          logger.fmt_debug("[STATUS]: Not staging item in %s", section.name)
        end
      end
    end

    --- Add all collected files
    if #files > 0 then
      git.index.add(files)
    end

    self:refresh({
      update_diffs = vim.tbl_map(function(v)
        return "*:" .. v.name
      end, selection.items),
    }, "stage_finish")
  end, { dispatch = true })
end

function M:unstage()
  return operation("unstage", function()
    local selection = self:get_selection()
    local mode = vim.api.nvim_get_mode()

    local files = {}

    for _, section in ipairs(selection.sections) do
      for _, item in ipairs(section.items) do
        if section.name == "staged" then
          local hunks = M.get_item_hunks(item, selection.first_line, selection.last_line, mode.mode == "V")

          if #hunks > 0 then
            for _, hunk in ipairs(hunks) do
              logger.fmt_debug(
                "[STATUS]: Unstaging hunk %d %d of %d %d, index_from %d",
                hunk.from,
                hunk.to,
                hunk.diff_from,
                hunk.diff_to,
                hunk.index_from
              )
              -- Apply works for both tracked and untracked
              git.index.apply(
                git.index.generate_patch(item, hunk, hunk.from, hunk.to, true),
                { cached = true, reverse = true }
              )
            end
          else
            table.insert(files, item.name)
          end
        end
      end
    end

    if #files > 0 then
      git.status.unstage(files)
    end

    self:refresh({
      status = true,
      diffs = vim.tbl_map(function(v)
        return "*:" .. v.name
      end, selection.items),
    }, "unstage_finish")
  end, { dispatch = true })
end

local function format_discard_message(files, hunk_count)
  if vim.api.nvim_get_mode() == "V" then
    return "Discard selection?"
  elseif hunk_count > 0 then
    return string.format("Discard %d hunks?", hunk_count)
  elseif #files > 1 then
    return string.format("Discard %d files?", #files)
  else
    return string.format("Discard %q?", files[1])
  end
end

function M:discard()
  return operation("discard", function()
    local selection = self:get_selection()
    local mode = vim.api.nvim_get_mode()

    git.index.update()

    local t = {}

    local hunk_count = 0
    local file_count = 0
    local files = {}

    for _, section in ipairs(selection.sections) do
      local section_name = section.name

      file_count = file_count + #section.items
      for _, item in ipairs(section.items) do
        table.insert(files, item.name)
        local hunks = M.get_item_hunks(item, selection.first_line, selection.last_line, mode.mode == "V")

        if #hunks > 0 then
          logger.fmt_debug("Discarding %d hunks from %q", #hunks, item.name)

          hunk_count = hunk_count + #hunks

          for _, hunk in ipairs(hunks) do
            table.insert(t, function()
              local patch = git.index.generate_patch(item, hunk, hunk.from, hunk.to, true)
              logger.fmt_debug("Patch: %s", patch)

              if section_name == "staged" then
                --- Apply both to the worktree and the staging area
                git.index.apply(patch, { index = true, reverse = true })
              else
                git.index.apply(patch, { reverse = true })
              end
            end)
          end
        else
          logger.fmt_debug("Discarding in section %s %s", section_name, item.name)
          table.insert(t, function()
            if section_name == "untracked" then
              a.util.scheduler()
              vim.fn.delete(git.cli.git_root() .. "/" .. item.name)
            elseif section_name == "unstaged" then
              git.index.checkout { item.name }
            elseif section_name == "staged" then
              git.index.reset { item.name }
              git.index.checkout { item.name }
            end
          end)
        end
      end
    end

    if
      not input.get_confirmation(
        format_discard_message(files, hunk_count),
        { values = { "&Yes", "&No" }, default = 2 }
      )
    then
      return
    end

    for i, v in ipairs(t) do
      logger.fmt_debug("Discard job %d", i)
      v()
    end

    self:refresh(nil, "discard")

    a.util.scheduler()
    vim.cmd("checktime")
  end, { dispatch = true })
end

function M:set_folds(to)
  return a.void(function()
    Collection.new(M.locations):each(function(l)
      l.folded = to[1]
      Collection.new(l.items):each(function(f)
        f.folded = to[2]
        if f.hunks then
          Collection.new(f.hunks):each(function(h)
            h.folded = to[3]
          end)
        end
      end)
    end)
    self:refresh(true, "set_folds")
  end)
end

--- Handles the GoToFile action on sections that contain a hunk
---@param item File
---@see section_has_hunks
function M:handle_section_item(item)
  if not item.absolute_path then
    notification.error("Cannot open file. No path found.")
    return
  end

  local row, col
  local cursor_row, cursor_col = unpack(vim.api.nvim_win_get_cursor(0))
  local hunk = M.get_item_hunks(item, cursor_row, cursor_row, false)[1]

  notification.delete_all()
  self:close()

  local relpath = vim.fn.fnamemodify(item.absolute_path, ":.")

  if not vim.o.hidden and vim.bo.buftype == "" and not vim.bo.readonly and vim.fn.bufname() ~= "" then
    vim.cmd("update")
  end

  if item.submodule then
    vim.schedule(function()
      require("neogit").open { cwd = relpath }
    end)
    return
  end

  vim.cmd("e " .. relpath)
  if hunk then
    local line_offset = cursor_row - hunk.first
    row = hunk.disk_from + line_offset - 1
    for i = 1, line_offset do
      if string.sub(hunk.lines[i], 1, 1) == "-" then
        row = row - 1
      end
    end
    -- adjust for diff sign column
    col = math.max(0, cursor_col - 1)
  end

  notification.delete_all()

  if not vim.o.hidden and vim.bo.buftype == "" and not vim.bo.readonly and vim.fn.bufname() ~= "" then
    vim.cmd("update")
  end

  local path = vim.fn.fnameescape(vim.fn.fnamemodify(item.absolute_path, ":~:."))
  vim.cmd(string.format("edit %s", path))

  if row and col then
    vim.api.nvim_win_set_cursor(0, { row, col })
  end
end

--- Returns the section header ref the user selected
---@param section Section
---@return string|nil
local function get_header_ref(section)
  if section.name == "head_branch_header" then
    return git.repo.head.branch
  end
  if section.name == "upstream_header" and git.repo.upstream.branch then
    return git.repo.upstream.branch
  end
  if section.name == "tag_header" and git.repo.head.tag.name then
    return git.repo.head.tag.name
  end
  if section.name == "push_branch_header" and git.repo.pushRemote.abbrev then
    return git.repo.pushRemote.abbrev
  end
  return nil
end

--- Determines if a given section is a status header section
---@param section Section
---@return boolean
local function is_section_header(section)
  return vim.tbl_contains(
    { "head_branch_header", "upstream_header", "tag_header", "push_branch_header" },
    section.name
  )
end

--- Determines if a given section contains hunks/diffs
---@param section Section
---@return boolean
local function section_has_hunks(section)
  return vim.tbl_contains({ "unstaged", "staged", "untracked" }, section.name)
end

--- Determines if a given section has a list of commits under it
---@param section Section
---@return boolean
local function section_has_commits(section)
  return vim.tbl_contains({
    "unmerged_pushRemote",
    "unpulled_pushRemote",
    "unmerged_upstream",
    "unpulled_upstream",
    "recent",
    "stashes",
  }, section.name)
end

--- Returns a curried table of mappings acting on the provided status buffer
function M:cmd_func_map()
  local mappings = {
    ["Close"] = function()
      self:close()
    end,
    ["InitRepo"] = a.void(git.init.init_repo),
    ["Depth1"] = self:set_folds { true, true, false },
    ["Depth2"] = self:set_folds { false, true, false },
    ["Depth3"] = self:set_folds { false, false, true },
    ["Depth4"] = self:set_folds { false, false, false },
    ["Toggle"] = function()
      self:toggle()
    end,
    ["Discard"] = { "nv", self:discard() },
    ["Stage"] = { "nv", self:stage() },
    ["StageUnstaged"] = a.void(function()
      git.status.stage_modified()
      self:refresh({ status = true, diffs = true }, "StageUnstaged")
    end),
    ["StageAll"] = a.void(function()
      git.status.stage_all()
      self:refresh({ update_diffs = true }, "StageUnstaged")
    end),
    ["Unstage"] = { "nv", self:unstage() },
    ["UnstageStaged"] = a.void(function()
      git.status.unstage_all()
      self:refresh({ update_diffs = true }, "UnstageStaged")
    end),
    ["CommandHistory"] = function()
      GitCommandHistory:new():show()
    end,
    ["Console"] = function()
      local process = require("neogit.process")
      process.show_console()
    end,
    ["TabOpen"] = function()
      local _, item = self:get_current_section_item()
      if item then
        vim.cmd("tabedit " .. item.name)
      end
    end,
    ["VSplitOpen"] = function()
      local _, item = self:get_current_section_item()
      if item then
        vim.cmd("vsplit " .. item.name)
      end
    end,
    ["SplitOpen"] = function()
      local _, item = self:get_current_section_item()
      if item then
        vim.cmd("split " .. item.name)
      end
    end,
    ["YankSelected"] = function()
      local yank

      local selection = require("neogit.status").get_selection()
      if selection.item then
        yank = selection.item.oid or selection.item.name
      elseif selection.commit then
        yank = selection.commit.oid
      elseif selection.section and selection.section.ref then
        yank = selection.section.ref
      elseif selection.section and selection.section.commit then
        yank = selection.section.commit.oid
      end

      if yank then
        if yank:match("^stash@{%d+}") then
          yank = git.rev_parse.oid(yank:match("^(stash@{%d+})"))
        end

        yank = string.format("'%s'", yank)
        vim.cmd.let("@+=" .. yank)
        vim.cmd.echo(yank)
      else
        vim.cmd("echo ''")
      end
    end,
    ["GoToPreviousHunkHeader"] = function()
      local section, item = self:get_current_section_item()
      if not section then
        return
      end

      local selection = self:get_selection()
      local on_hunk = item and self:current_line_is_hunk()

      if item and not on_hunk then
        local _, prev_item = get_section_item_for_line(self, vim.fn.line(".") - 1)
        if prev_item then
          vim.api.nvim_win_set_cursor(0, { prev_item.hunks[#prev_item.hunks].first, 0 })
        end
      elseif on_hunk then
        local hunks = M.get_item_hunks(selection.item, 0, selection.first_line - 1, false)
        local hunk = hunks[#hunks]

        if hunk then
          vim.api.nvim_win_set_cursor(0, { hunk.first, 0 })
          vim.cmd("normal! zt")
        else
          local _, prev_item = get_section_item_for_line(self, vim.fn.line(".") - 2)
          if prev_item then
            vim.api.nvim_win_set_cursor(0, { prev_item.hunks[#prev_item.hunks].first, 0 })
          end
        end
      end
    end,
    ["GoToNextHunkHeader"] = function()
      local section, item = self:get_current_section_item()
      if not section then
        return
      end

      local on_hunk = item and self:current_line_is_hunk()

      if item and not on_hunk then
        vim.api.nvim_win_set_cursor(0, { vim.fn.line(".") + 1, 0 })
      elseif on_hunk then
        local selection = self:get_selection()
        local hunks =
          M.get_item_hunks(selection.item, selection.last_line + 1, selection.last_line + 1, false)

        local hunk = hunks[1]

        assert(hunk, "Hunk is nil")
        assert(item, "Item is nil")

        if hunk.last == item.last then
          local _, next_item = get_section_item_for_line(self, hunk.last + 1)
          if next_item then
            vim.api.nvim_win_set_cursor(0, { next_item.first + 1, 0 })
          end
        else
          vim.api.nvim_win_set_cursor(0, { hunk.last + 1, 0 })
        end
        vim.cmd("normal! zt")
      end
    end,
    ["GoToFile"] = a.void(function()
      a.util.scheduler()
      local section, item = self:get_current_section_item()
      if not section then
        return
      end
      if item then
        if section_has_hunks(section) then
          ---@type File
          ---@diagnostic disable-next-line: assign-type-mismatch
          local item = item
          self:handle_section_item(item)
        else
          if section_has_commits(section) then
            if M.commit_view and M.commit_view.is_open then
              M.commit_view:close()
            end
            M.commit_view = CommitView.new(item.name:match("(.-):? "))
            M.commit_view:open()
          end
        end
      else
        if is_section_header(section) then
          local ref = get_header_ref(section)
          if not ref then
            return
          end
          if M.commit_view and M.commit_view.is_open then
            M.commit_view:close()
          end
          M.commit_view = CommitView.new(ref)
          M.commit_view:open()
        end
      end
    end),

    ["RefreshBuffer"] = function()
      notification.info("Refreshing Status")
      self:dispatch_refresh(nil, "manual")
    end,
  }

  local popups = require("neogit.popups")
  --- Load the popups from the centralized popup file
  for _, v in ipairs(popups.mappings_table(self)) do
    --- { name, display_name, mapping }
    if mappings[v[1]] then
      error("Neogit: Mapping '" .. v[1] .. "' is already in use!")
    end

    mappings[v[1]] = v[3]
  end

  return mappings
end

---Sets decoration provider for buffer
function M:set_decoration_provider()
  local decor_ns = api.nvim_create_namespace("NeogitStatusDecor")
  local context_ns = api.nvim_create_namespace("NeogitStatusContext")

  local function on_start()
    return self.buffer:exists() and self.buffer:is_focused()
  end

  local function on_win()
    self.buffer:clear_namespace(decor_ns)
    self.buffer:clear_namespace(context_ns)

    -- first and last lines of current context based on cursor position, if available
    local _, _, _, first, last = self:save_cursor_location()
    local cursor_line = vim.fn.line(".")

    for line = fn.line("w0"), fn.line("w$") do
      local text = self.buffer:get_line(line)[1]
      if text then
        local highlight
        local start = string.sub(text, 1, 1)
        local _, _, hunk, _, _ = self:save_cursor_location(line)

        if start == head_start then
          highlight = "NeogitHunkHeader"
        elseif line == cursor_line then
          highlight = "NeogitCursorLine"
        elseif start == add_start then
          highlight = "NeogitDiffAdd"
        elseif start == del_start then
          highlight = "NeogitDiffDelete"
        elseif hunk then
          highlight = "NeogitDiffContext"
        end

        if highlight then
          self.buffer:set_extmark(decor_ns, line - 1, 0, { line_hl_group = highlight, priority = 9 })
        end

        if
          not config.values.disable_context_highlighting
          and first
          and last
          and line >= first
          and line <= last
          and highlight ~= "NeogitCursorLine"
        then
          self.buffer:set_extmark(
            context_ns,
            line - 1,
            0,
            { line_hl_group = (highlight or "NeogitDiffContext") .. "Highlight", priority = 10 }
          )
        end
      end
    end
  end

  self.buffer:set_decorations(decor_ns, { on_start = on_start, on_win = on_win })
end

function M.find(cwd)
  local buffer = status_buffers[cwd]
  if buffer then
    if buffer.buffer:is_valid() then
      return buffer
    else
      status_buffers[cwd] = nil
    end
  end
end

--- Creates a new status buffer
---@return StatusBuffer
function M.create(kind, cwd)
  kind = kind or config.values.kind

  local existing = M.find(cwd)
  if existing then
    logger.debug("Status buffer already exists. Focusing the existing one")
    existing.buffer:show(true)
    return existing
  end

  logger.debug("[STATUS BUFFER]: Creating...")

  local status_buffer = { cwd = cwd, locations = {}, outdated = {} }
  setmetatable(status_buffer, M)

  status_buffers[cwd] = status_buffer

  local buffer = Buffer.create {
    name = "NeogitStatus",
    filetype = "NeogitStatus",
    kind = kind,
    disable_line_numbers = config.values.disable_line_numbers,
    ---@param buffer Buffer
    initialize = function(buffer, win)
      logger.debug(string.format("[STATUS BUFFER]: Initializing status buffer %d", buffer.handle))

      status_buffer.buffer = buffer

      status_buffer.prev_autochdir = vim.o.autochdir

      -- Breaks when initializing a new repo in CWD
      if cwd and win then
        status_buffer.old_cwd = vim.fn.getcwd(win)

        vim.api.nvim_win_call(win, function()
          vim.cmd.lcd(cwd)
        end)
      end

      vim.o.autochdir = false

      local mappings = buffer.mmanager.mappings
      local func_map = status_buffer:cmd_func_map()
      local keys = vim.tbl_extend("error", config.values.mappings.status, config.values.mappings.popup)

      for key, val in pairs(keys) do
        if val and val ~= "" then
          local func = func_map[val]

          if func ~= nil then
            if type(func) == "function" then
              mappings.n[key] = func
            elseif type(func) == "table" then
              for _, mode in pairs(vim.split(func[1], "")) do
                mappings[mode][key] = func[2]
              end
            end
          elseif type(val) == "function" then -- For user mappings that are either function values...
            mappings.n[key] = val
          elseif type(val) == "string" then -- ...or VIM command strings
            mappings.n[key] = function()
              vim.cmd(val)
            end
          end
        end
      end

      logger.debug("[STATUS BUFFER]: Dispatching initial render")
      status_buffer:refresh(nil, "Buffer.create")
    end,
    after = function()
      vim.cmd([[setlocal nowrap]])
      M.watcher = watcher.new(git.repo:git_path():absolute())

      if M.cursor_location then
        vim.wait(2000, function()
          return not M.is_refresh_locked()
        end)

        local ok, _ = pcall(status_buffer.restore_cursor_location, status_buffer, unpack(M.cursor_location))
        if ok then
          M.cursor_location = nil
        end
      end
    end,
  }

  status_buffer.buffer = buffer

  status_buffer:set_decoration_provider()

  return status_buffer
end

-- M.toggle = toggle
-- M.reset = reset
-- M.dispatch_reset = dispatch_reset
-- M.refresh = refresh
-- M.dispatch_refresh = dispatch_refresh
-- M.refresh_viml_compat = refresh_viml_compat
-- M.refresh_manually = refresh_manually
-- M.get_current_section_item = get_current_section_item
-- M.close = close

function M:enable()
  self.disabled = false
end

function M:disable()
  self.disabled = true
end

function M:get_status()
  return self.status
end

function M.chdir(dir)
  local destination = require("plenary.path").new(dir)
  vim.wait(5000, function()
    return destination:exists()
  end)

  logger.debug("[STATUS] Changing Dir: " .. dir)
  M.old_cwd = dir
  vim.cmd.cd(dir)
  vim.loop.chdir(dir)
  M.reset_all()
end

return M
