/* Rendering is local-only. All imported text is inserted as text nodes. */
const ReadingReader = (() => {
  let documentData;
  let selected = null;
  let page;
  const root = () => document.getElementById('page');
  const card = () => document.getElementById('translation');
  function notify(event, index) { window.webkit.messageHandlers.reading.postMessage({ event, index }); }

  function rubyText(text) {
    const fragment = document.createDocumentFragment();
    const pattern = /([\p{Script=Han}々〆ヶ]+)\[([^\]]+)\]/gu;
    let previous = 0;
    for (const match of text.matchAll(pattern)) {
      fragment.append(document.createTextNode(text.slice(previous, match.index)));
      const ruby = document.createElement('ruby');
      ruby.append(document.createTextNode(match[1]));
      const annotation = document.createElement('rt');
      annotation.textContent = match[2];
      ruby.append(annotation);
      fragment.append(ruby);
      previous = match.index + match[0].length;
    }
    fragment.append(document.createTextNode(text.slice(previous)));
    return fragment;
  }

  function segment(part) {
    const span = document.createElement('span');
    span.className = 'sentence';
    span.dataset.sentence = String(part[0]);
    span.tabIndex = 0;
    span.setAttribute('role', 'button');
    span.setAttribute('aria-label', documentData.sentences[part[0]].text);
    span.append(rubyText(part[1]));
    span.addEventListener('click', () => choose(part[0]));
    span.addEventListener('keydown', event => {
      if (['Enter', ' '].includes(event.key)) { event.preventDefault(); choose(part[0]); }
    });
    return span;
  }

  function choose(index) {
    const reveal = selected === index;
    select(index, reveal);
    notify('select', index);
  }

  function playButton(index) {
    const button = document.createElement('button');
    button.className = 'play-disc';
    button.setAttribute('aria-label', 'Play selected sentence');
    button.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4.8L11 8l-5 3.2z" fill="currentColor"/></svg>';
    button.addEventListener('click', event => { event.stopPropagation(); notify('play', index); });
    return button;
  }

  function showTranslation(index) {
    const bubble = card();
    bubble.textContent = documentData.sentences[index].translation;
    bubble.hidden = false;
    const elements = [...document.querySelectorAll(`[data-sentence="${index}"]`)];
    const last = elements.at(-1).getBoundingClientRect();
    bubble.style.left = '18px';
    bubble.style.top = `${window.scrollY + last.bottom + 10}px`;
    if (last.bottom + bubble.offsetHeight + 10 > window.innerHeight) {
      bubble.style.top = `${Math.max(window.scrollY + 8, window.scrollY + last.top - bubble.offsetHeight - 10)}px`;
    }
  }

  function select(index, reveal = false) {
    if (selected === index && !reveal) return;
    document.querySelectorAll('.selected').forEach(element => element.classList.remove('selected'));
    document.querySelectorAll('.play-anchor').forEach(element => element.remove());
    card().hidden = true;
    selected = index;
    const elements = [...document.querySelectorAll(`[data-sentence="${index}"]`)];
    elements.forEach(element => element.classList.add('selected'));
    if (!elements.length) return;
    const anchor = document.createElement('span');
    anchor.className = 'play-anchor';
    anchor.append(playButton(index));
    elements[0].before(anchor);
    if (reveal) showTranslation(index);
  }

  function textPage() {
    const columns = document.createElement('div');
    columns.className = 'columns';
    for (const parts of page.columns) {
      const column = document.createElement('span');
      column.className = 'column';
      parts.forEach(part => column.append(segment(part)));
      columns.append(column);
    }
    root().append(columns);
    for (const part of page.notes ?? []) appendAside(part);
    if (page.biography) appendAside(page.biography);
  }

  function flowingText() {
    const container = document.createElement('div');
    container.className = 'columns';
    let paragraph = document.createElement('p');
    container.append(paragraph);
    for (const part of page.columns.flat()) {
      if (part[1].startsWith('　') && paragraph.childNodes.length) {
        paragraph = document.createElement('p');
        container.append(paragraph);
      }
      paragraph.append(segment(part));
    }
    root().append(container);
    for (const part of page.notes ?? []) appendAside(part);
    if (page.biography) appendAside(page.biography);
  }

  function titlePage() {
    const header = document.createElement('header');
    header.className = 'book-heading';
    const title = document.createElement('h1');
    title.textContent = documentData.title;
    const author = document.createElement('p');
    author.append(rubyText(documentData.authorReading ?? documentData.author));
    header.append(title, author);
    root().append(header);
    illustration(true);
  }

  function appendAside(part) {
    const note = document.createElement('p');
    note.className = 'source-note';
    note.append(segment(part));
    root().append(note);
  }

  function illustration(cover = false) {
    const frame = document.createElement('div');
    frame.className = 'illustration';
    const ratio = page.imageAspectRatio ?? 0.7;
    frame.style.aspectRatio = String(cover ? 1.6 : ratio);
    if (page.imageCrop) frame.style.aspectRatio = String(ratio * page.imageCrop.width / page.imageCrop.height);
    const image = document.createElement('img');
    image.id = 'illustration';
    image.alt = `Illustration, page ${page.number}`;
    if (page.imageCrop) {
      const crop = page.imageCrop;
      image.style.width = `${10000 / crop.width}%`;
      image.style.height = `${10000 / crop.height}%`;
      image.style.left = `${-crop.left * 100 / crop.width}%`;
      image.style.top = `${-crop.top * 100 / crop.height}%`;
    }
    frame.append(image);
    root().append(frame);
  }

  function dismissTranslation(event) {
    if (!event.target.closest('.sentence') && !event.target.closest('#translation')) card().hidden = true;
  }

  function mount(data, pageIndex, selection) {
    documentData = data;
    page = data.pages[pageIndex];
    const original = root().classList.contains('original');
    if (page.kind === 'title' && original) titlePage();
    if (page.kind === 'illustration') illustration();
    if (original) textPage(); else flowingText();
    if (selection !== null) {
      select(selection);
      document.querySelector(`[data-sentence="${selection}"]`)?.scrollIntoView({ block: 'center' });
    }
    document.addEventListener('click', dismissTranslation);
  }
  window.readerSelect = select;
  window.readerImage = value => { const image = document.getElementById('illustration'); if (image) image.src = value; };
  return { mount, rubyText };
})();
