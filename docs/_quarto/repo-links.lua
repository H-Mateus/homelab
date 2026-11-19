-- Point relative links at non-page files (e.g. ../opentofu/live/homelab/main.tf,
-- or a directory) to the file on GitHub. Those work when browsing the repo
-- but aren't part of the site. Links to .md/.qmd pages are left for Quarto
-- to turn into .html.

local REPO = "https://github.com/H-Mateus/homelab/blob/main/"

local function collapse(path)
  local out = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #out == 0 then return nil end -- escapes the repo
      table.remove(out)
    elseif part ~= "." then
      table.insert(out, part)
    end
  end
  return table.concat(out, "/")
end

function Link(el)
  local target = el.target
  if target == "" or target:match("^#") or target:match("^%a[%w+.-]*:") then
    return nil -- anchor, or has a scheme (https:, mailto:, ...)
  end
  local path, frag = target:match("^([^#]*)(.*)$")
  local ext = path:match("%.(%w+)$")
  if ext and (ext == "md" or ext == "qmd" or ext == "html") then
    return nil
  end

  local rel
  if path:sub(1, 1) == "/" then
    rel = path:sub(2) -- GitHub treats a leading / as the repo root
  else
    local project = quarto.project.directory
    local input = quarto.doc.input_file
    if not project or not input then return nil end
    local dir = pandoc.path.directory(pandoc.path.make_relative(input, project))
    rel = (dir == "." and "" or dir .. "/") .. path
  end
  rel = collapse(rel)
  if not rel then return nil end
  el.target = REPO .. rel .. frag
  return el
end
