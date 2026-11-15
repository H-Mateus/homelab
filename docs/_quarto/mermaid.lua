-- Render GitHub-style ```mermaid fences as diagrams.
--
-- Quarto only draws Mermaid from executable {mermaid} cells, which aren't
-- allowed in .md files and which GitHub shows as plain code. This keeps the
-- source GitHub-friendly: each ```mermaid block becomes the same
-- <pre class="mermaid mermaid-js"> element Quarto emits for {mermaid} cells,
-- and the page gets Quarto's own bundled mermaid runtime (same version and
-- light/dark theming as a native cell, no CDN).

local share = os.getenv("QUARTO_SHARE_PATH")
local added = false

local function add_runtime()
  if added then return end
  added = true
  local dir = share .. "/formats/html/mermaid/"
  quarto.doc.add_html_dependency({
    name = "quarto-diagram",
    scripts = {
      { path = dir .. "mermaid.min.js" },
      { path = dir .. "mermaid-init.js", afterBody = true },
    },
    stylesheets = { dir .. "mermaid.css" },
  })
end

local function escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

function CodeBlock(el)
  if not el.classes:includes("mermaid") or not quarto.doc.is_format("html") then
    return nil
  end
  if not share then
    quarto.log.warning("QUARTO_SHARE_PATH unset; leaving mermaid block as code")
    return nil
  end
  add_runtime()
  return pandoc.RawBlock("html",
    '<div class="cell"><pre class="mermaid mermaid-js">' .. escape(el.text) .. "</pre></div>")
end
