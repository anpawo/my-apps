'use strict';
// The run panel (Swift `RunPanel`): a shell code block's Run button, or an inline `sudo …`, offers its command above
// the composer; once Run is clicked the core runs it on a terminal of its own (run.rs). While that terminal hides its
// echo, the field is a password field and its line goes to the terminal only, never to the agent.
(() => {
  const SHELLS = ['bash', 'sh', 'zsh', 'shell', 'console', 'fish', 'terminal'];
  // Swift: the panel moves up from the bottom with a fade, as the question panel, on .smooth(0.3); reduced motion fades.
  const SLIDE_MS = 300;
  const SLIDE_EASE = 'cubic-bezier(.25, .1, .25, 1)';
  const QUICK_MS = 100;
  const PLAY = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 2.9v10.2c0 .6.6.9 1.1.6l8-5.1c.5-.3.5-.9 0-1.2l-8-5.1c-.5-.3-1.1 0-1.1.6z"/></svg>';
  const TERMINAL = '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="1.5" y="2.5" width="13" height="11" rx="2.5"/><path d="M4.5 6l2 2-2 2M8 10.5h3.5"/></svg>';

  const $ = id => document.getElementById(id);
  // Straight to the core: app.js's post also fires a DOM event, which would carry a password into the page.
  const post = message => window.ipc.postMessage(JSON.stringify(message));
  let cwd = '';
  let run = null;
  let runs = 0;
  let parts = null;

  function make(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(className, label, action) {
    const node = make('button', className, label);
    node.type = 'button';
    node.addEventListener('click', action);
    return node;
  }

  function runnable(code, language) {
    return SHELLS.includes(language.toLowerCase()) || code.trimStart().startsWith('sudo ');
  }

  function home(path) {
    return path.replace(/^\/Users\/[^/]+(?=\/|$)/, '~');
  }

  // Code blocks and inline code are drawn by app.js; each one that runs gets its Run button or its link once.
  function decorate() {
    for (const figure of document.querySelectorAll('#rows figure.code:not(.markdown)')) {
      const caption = figure.querySelector('figcaption');
      const code = figure.querySelector('pre code');
      if (!caption || !code || caption.querySelector('button.run')) continue;
      const language = (code.className.match(/language-(\S+)/) || [])[1] || '';
      if (!runnable(code.textContent, language)) continue;
      const play = make('button', 'run');
      play.type = 'button';
      play.innerHTML = PLAY;
      play.title = 'Run in VCX: the output shows above the composer, a password stays in VCX';
      play.ariaLabel = 'Run command';
      const copy = caption.querySelector('button.copy');
      if (copy) copy.before(play);
      else caption.append(play);
    }
    for (const code of document.querySelectorAll('#rows .prose code:not(pre code):not(.run-link)')) {
      if (!code.textContent.trimStart().startsWith('sudo ')) continue;
      code.classList.add('run-link');
      code.tabIndex = 0;
      code.role = 'link';
      code.title = 'Run in VCX: a password stays in VCX';
    }
  }

  function offer(command) {
    if (run?.state === 'running') return;
    run = { id: `run-${++runs}`, command, state: 'ready', output: '', hidden: false, code: null };
    build();
    draw();
    parts.go.focus();
  }

  function start() {
    post({ type: 'run', id: run.id, command: run.command });
    run.state = 'running';
    draw();
    parts.field.focus();
  }

  function close() {
    if (!run || run.state === 'running') return;
    run = null;
    const card = parts.card;
    parts = null;
    slide(card, false).then(() => card.remove());
    $('input')?.focus();
  }

  function title() {
    if (run.state === 'ready') return 'Run this command?';
    if (run.state === 'running') return run.hidden ? 'Running · the command asks for a password' : 'Running';
    return run.code === 0 ? 'Done · exit 0' : `Failed · exit ${run.code}`;
  }

  // In the bar dialog (WT-072), as the permission prompt. Built once a run, then changed in place, so output that
  // arrives while he types never takes the field's focus or its text.
  function build() {
    parts?.card.remove();
    const card = make('section', 'dialog light');
    card.id = 'run';
    const head = make('div', 'bar'), name = make('div'), icon = make('span', 'icon'), heading = make('p');
    icon.innerHTML = TERMINAL;
    name.append(icon, heading);
    head.append(name);
    const body = make('div', 'body');
    const command = make('pre', 'command', run.command);
    const output = make('pre', 'output');
    body.append(command, output);
    const foot = make('div', 'foot');
    const where = make('p', 'where first');
    const field = make('input', 'line first');
    field.autocomplete = 'off';
    field.spellcheck = false;
    field.addEventListener('keydown', event => {
      if (event.key !== 'Enter' || event.isComposing) return;
      event.preventDefault();
      post({ type: 'runInput', id: run.id, line: field.value });
      field.value = '';
    });
    const cancel = button('ub outline', 'Cancel', close);
    const stop = button('ub outline', 'Stop', () => post({ type: 'runStop', id: run.id }));
    stop.title = 'Send a hangup to the command';
    const go = button('ub primary', 'Run', start);
    foot.append(where, field, cancel, stop, go);
    card.append(head, body, foot);
    // Return and Escape answer the panel's buttons, before the composer's own keys take them.
    card.addEventListener('keydown', event => {
      if (event.key !== 'Enter' && event.key !== 'Escape') return;
      if (event.key === 'Escape') close();
      else if (run.state === 'ready' && event.target.tagName !== 'BUTTON') start();
      event.stopPropagation();
    });
    parts = { card, heading, output, where, field, cancel, stop, go };
    $('composer').before(card);
    slide(card, true);
  }

  function slide(card, shown) {
    const quick = matchMedia('(prefers-reduced-motion: reduce)').matches;
    const fade = { opacity: shown ? [0, 1] : [1, 0] };
    const move = card.animate(quick ? fade : { ...fade, translate: shown ? ['0 100%', '0 0'] : ['0 0', '0 100%'] },
      { duration: quick ? QUICK_MS : SLIDE_MS, easing: SLIDE_EASE, fill: shown ? 'none' : 'forwards' });
    // An unshown window may never finish an animation.
    return Promise.race([move.finished, new Promise(done => setTimeout(done, move.effect.getTiming().duration))]);
  }

  function draw() {
    const { heading, output, where, field, cancel, stop, go } = parts;
    const running = run.state === 'running', finished = run.state === 'finished';
    heading.textContent = title();
    heading.classList.toggle('done', finished && run.code === 0);
    heading.classList.toggle('failed', finished && run.code !== 0);
    output.hidden = !run.output;
    output.textContent = run.output;
    output.scrollTop = output.scrollHeight;
    where.hidden = run.state !== 'ready';
    where.textContent = `Runs in ${home(cwd)} on its own terminal`;
    field.hidden = !running;
    field.type = run.hidden ? 'password' : 'text';
    field.placeholder = run.hidden ? 'Password (stays in VCX, never sent to the agent), then Return' : 'Input for the command, then Return';
    cancel.hidden = running;
    cancel.textContent = finished ? 'Close' : 'Cancel';
    stop.hidden = !running;
    go.hidden = run.state !== 'ready';
    if (finished && document.activeElement === field) parts.cancel.focus();
  }

  function receive(message) {
    if (message.meta?.cwd !== undefined) cwd = message.meta.cwd;
    if (message.type !== 'run' || message.id !== run?.id) return;
    Object.assign(run, { state: message.state, output: message.output || '', hidden: Boolean(message.hidden), code: message.code ?? null });
    draw();
  }

  document.addEventListener('click', event => {
    const play = event.target.closest('#rows figure.code button.run');
    const link = event.target.closest('#rows code.run-link');
    if (play) offer(play.closest('figure.code').querySelector('pre code').textContent);
    else if (link) offer(link.textContent);
  });
  document.addEventListener('keydown', event => {
    if (event.key !== 'Enter' || !event.target.matches?.('#rows code.run-link')) return;
    event.preventDefault();
    event.stopPropagation();
    offer(event.target.textContent);
  }, true);
  const rows = $('rows');
  if (rows) new MutationObserver(decorate).observe(rows, { childList: true, subtree: true });

  window.vcxRun = { offer, receive, runnable, get open() { return Boolean(run) } };
})();
