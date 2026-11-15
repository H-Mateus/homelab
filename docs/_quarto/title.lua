-- The pages are GitHub-style Markdown with no front matter: their title is
-- the leading `# Heading`. Lift it into `title` (shown in Quarto's title
-- block) and `pagetitle` (the browser tab, which Quarto otherwise fills from
-- the file name, so every stack page would read "readme").

function Pandoc(doc)
  if doc.meta.title then return nil end
  local first = doc.blocks[1]
  if not first or first.t ~= "Header" or first.level ~= 1 then return nil end
  doc.meta.title = pandoc.MetaInlines(first.content)
  doc.meta.pagetitle = pandoc.utils.stringify(first.content)
  doc.blocks:remove(1)
  return doc
end
