function renderMarkdown(source) {
  const content = document.getElementById('content');
  content.innerHTML = DOMPurify.sanitize(marked.parse(source, { gfm: true }), { USE_PROFILES: { html: true } });
}
