'use strict';
// The agent's questions for Marius, one at a time above the composer, as the Swift `QuestionPanel`: numbered options,
// Cancel, a hidden field for a secret. The page sends the answer; the core hands it to the worker.
(() => {
  const DIGITS = /^[1-9]$/;
  const $ = id => document.getElementById(id);
  const panel = $('question');
  let request = null;
  let step = 0;
  let typed = {};
  let picked = {};
  // A request answered here stays hidden until the core drops it, so a late redraw cannot show it twice.
  const answered = new Set();

  const make = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const key = card => `${card.id}:${JSON.stringify(card.rpcID)}`;
  const question = () => request && request.questions[step];
  const send = message => window.vcx.post(message);

  function answer(result) {
    answered.add(key(request));
    send({ type: 'answer', rpcID: request.rpcID, method: request.method, result });
    request = null;
    draw();
  }

  // The Swift `questionAnswers`: chosen options in their listed order, then a typed answer.
  function answers() {
    const result = {};
    request.questions.forEach(asked => {
      const values = asked.multiple ? asked.options.map(option => option.label).filter(label => (picked[asked.id] || new Set()).has(label)) : [];
      if (typed[asked.id] && typed[asked.id].trim()) values.push(typed[asked.id].trim());
      if (values.length) result[asked.id] = { answers: values };
    });
    return result;
  }

  function advance() {
    step += 1;
    if (step < request.questions.length) return draw();
    answer({ answers: answers() });
  }

  function choose(number) {
    const asked = question();
    const option = asked && asked.options[number - 1];
    if (!option) return false;
    if (asked.multiple) {
      const set = picked[asked.id] || (picked[asked.id] = new Set());
      if (set.has(option.label)) set.delete(option.label);
      else set.add(option.label);
      draw();
    } else {
      typed[asked.id] = option.label;
      advance();
    }
    return true;
  }

  // A typed answer, from the hidden field or from the composer while a question is open. False when nothing was asked.
  function reply(text) {
    const asked = question();
    if (!asked) return false;
    if (text.trim()) typed[asked.id] = text.trim();
    if (answers()[asked.id]) advance();
    return true;
  }

  function option(asked, choice, index) {
    const chosen = asked.multiple && (picked[asked.id] || new Set()).has(choice.label);
    const button = make('button', chosen ? 'option chosen' : 'option');
    button.type = 'button';
    button.dataset.number = String(index + 1);
    const words = make('span', 'words');
    words.append(make('span', 'option-label', choice.label));
    if (choice.description) words.append(make('span', 'option-detail', choice.description));
    button.append(make('span', 'number', String(index + 1)), words);
    button.addEventListener('mousedown', event => event.preventDefault());
    button.addEventListener('click', () => choose(index + 1));
    return button;
  }

  function draw() {
    const asked = question();
    panel.hidden = !asked;
    if (!asked) return panel.replaceChildren();
    const head = make('div', 'question-head');
    const title = request.questions.length > 1 ? `Question ${step + 1} of ${request.questions.length}` : 'Your answer is needed';
    head.append(make('span', 'question-icon'), make('span', 'question-title', [title, asked.header].filter(Boolean).join(' · ')));
    const cancel = make('button', 'question-cancel', 'Cancel');
    cancel.type = 'button';
    cancel.title = 'Answer nothing and let the agent continue';
    cancel.addEventListener('click', () => answer({ answers: {} }));
    head.append(cancel);
    const options = make('div', 'options');
    options.append(...asked.options.map((choice, index) => option(asked, choice, index)));
    panel.replaceChildren(head, make('p', 'question-text', asked.question), options);
    panel.dataset.request = request.id;
    if (asked.secret) {
      const field = make('input', 'secret');
      field.type = 'password';
      field.placeholder = 'Your answer (hidden), then Return';
      field.setAttribute('aria-label', 'Your answer, hidden');
      field.addEventListener('keydown', event => {
        if (event.key !== 'Enter') return;
        event.preventDefault();
        reply(field.value);
      });
      panel.append(field);
      field.focus();
    } else if (asked.multiple) {
      panel.append(make('p', 'question-hint', 'Numbers toggle choices · Return confirms'));
    }
  }

  function receive(message, meta) {
    if (message.type !== 'full' && !message.meta) return;
    const live = new Set((meta.requests || []).map(key));
    for (const done of [...answered]) if (!live.has(done)) answered.delete(done);
    const next = (meta.requests || []).find(card => card.kind === 'question' && !answered.has(key(card)));
    if (!next) request = null;
    else if (!request || key(request) !== key(next)) {
      request = next;
      step = 0;
      typed = {};
      picked = {};
    }
    draw();
  }

  // Numbers choose and Return confirms while nothing is being typed: the composer is empty or nothing editable has the focus.
  addEventListener('keydown', event => {
    if (!question() || event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return;
    const target = event.target;
    const composer = $('input');
    const typing = target.closest && target.closest('input, textarea, [contenteditable="true"]');
    if (typing && !(target === composer && !composer.value)) return;
    if (DIGITS.test(event.key) ? choose(Number(event.key)) : event.key === 'Enter' && question().multiple && reply('')) {
      event.preventDefault();
      event.stopPropagation();
    }
  }, true);

  window.vcxQuestions = { receive, reply, choose, get open() { return Boolean(question()) } };
})();
