import { catalog, featuredIds, repositories } from './catalog.js';
import { createPlayer } from './player.js';

const routes = { home: '首页', discover: '片库', search: '搜索', library: '我的片单', sources: '片源与授权' };
const root = document.querySelector('#app-view');
const detail = document.querySelector('#detail-dialog');
const playerDialog = document.querySelector('#player-dialog');
const byId = new Map(catalog.map((show) => [show.id, show]));
const genres = [...new Set(catalog.flatMap((show) => show.genres))];
const stateKey = 'interval-cinema-v1';

function loadState() {
  try {
    const data = JSON.parse(localStorage.getItem(stateKey));
    return {
      saved: new Set((Array.isArray(data?.saved) ? data.saved : []).filter((id) => byId.has(id))),
      progress: data?.progress && typeof data.progress === 'object' ? data.progress : {},
    };
  } catch {
    return { saved: new Set(), progress: {} };
  }
}

const state = loadState();
let lastWrite = 0;
let toastTimer;
let activePage = '';
let featuredIndex = 0;
let activeGenre = '全部';
let searchQuery = '';
let detailTrigger;
let detailShow;

function persist() {
  try {
    localStorage.setItem(stateKey, JSON.stringify({ saved: [...state.saved], progress: state.progress }));
  } catch {
    // In-memory viewing state remains usable with storage disabled.
  }
}

const player = createPlayer({
  dialog: playerDialog,
  onProgress(id, episode, seconds, duration, ended) {
    if (!byId.has(id) || (!ended && seconds < 1)) return;
    state.progress[id] = { episode, seconds, duration, ended, updated: Date.now() };
    if (ended || Date.now() - lastWrite > 900) {
      persist();
      lastWrite = Date.now();
    }
  },
  onClose() {
    const focused = document.activeElement;
    persist();
    renderDynamicShelves();
    if (!focused.isConnected && focused.matches('[data-action="play"][data-id]')) {
      (root.querySelector(`[data-action="play"][data-id="${focused.dataset.id}"]`) || root)
        .focus({ preventScroll: true });
    }
  },
});

const icon = (name) => `<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;
const closeButton = '<button class="icon-button close-button" type="button" data-close-detail aria-label="关闭详情">' + icon('close') + '</button>';
const posterStyle = (show) => `style="--poster-position:${show.position || '50% 50%'}"`;

function detailButton(show) {
  return `<button class="button secondary" data-action="detail" data-id="${show.id}" data-tv>影片详情</button>`;
}

function playButton(show, label = '立即播放') {
  return `<button class="button primary" data-action="play" data-id="${show.id}" data-tv>${icon('play')}${label}</button>`;
}

function saveButton(show) {
  const saved = state.saved.has(show.id);
  return `<button class="button secondary save-button" data-action="save" data-id="${show.id}" aria-pressed="${saved}" data-tv>${icon(saved ? 'check' : 'plus')}${saved ? '已收藏' : '加入片单'}</button>`;
}

function card(show, progress) {
  const series = show.episodes.length > 1;
  const percent = progress && Number.isFinite(progress.duration) && progress.duration > 0
    ? Math.min(100, Math.round(progress.seconds / progress.duration * 100))
    : 0;
  const meta = series ? `${show.episodes.length} 集` : show.length;
  return `<article class="film-card">
    <button class="poster" ${posterStyle(show)} type="button" data-action="${progress ? 'play' : 'detail'}" data-id="${show.id}" aria-label="${progress ? '继续观看' : '查看影片'} ${show.title}" data-tv>
      <img src="${show.image}" alt="" width="440" height="550" loading="lazy">
      <span class="poster-shade"></span>
      <span class="poster-tag">${show.genres[0]}</span>
      <span class="poster-title">${show.title}<span>${show.original}</span></span>
      <span class="poster-play">${icon('play')}</span>
      ${progress ? `<span class="progress-line" aria-hidden="true"><i style="width:${percent}%"></i></span>` : ''}
    </button>
    <div class="film-meta">
      <span>${progress ? `已看到 ${formatTime(progress.seconds)}` : `${show.genres[0]} <span class="meta-dot">·</span> ${meta}`}</span>
      <button class="mini-save" type="button" data-action="save" data-id="${show.id}" aria-label="${state.saved.has(show.id) ? '取消收藏' : '收藏'} ${show.title}" title="${state.saved.has(show.id) ? '取消收藏' : '收藏'}" aria-pressed="${state.saved.has(show.id)}" data-tv>
        ${icon(state.saved.has(show.id) ? 'check' : 'plus')}
      </button>
    </div>
  </article>`;
}

function formatTime(value) {
  const seconds = Math.max(0, Math.floor(Number(value) || 0));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

function shelf(shows, progress = false) {
  return `<div class="film-grid">${shows.map((show) => card(show, progress ? state.progress[show.id] : null)).join('')}</div>`;
}

function hero() {
  const show = byId.get(featuredIds[featuredIndex]);
  return `<div class="hero-frame" data-enter>
    <img class="hero-image" src="${show.hero || show.image}" alt="" width="1920" height="900" ${posterStyle(show)} fetchpriority="high">
    <div class="hero-glaze"></div>
    <div class="hero-info">
      <div class="eyebrow"><span></span> 本期精选</div>
      <h1>${show.title}</h1>
      <p class="hero-original" lang="en">${show.original}</p>
      <div class="title-meta"><span>${show.year}</span><span>${show.genres[0]}</span><span>${show.length}</span>${show.episodes[0].tracks ? '<span>中文字幕</span>' : ''}</div>
      <p class="hero-description">${show.description}</p>
      <div class="actions">${playButton(show)}${detailButton(show)}</div>
    </div>
    <div class="hero-switch" aria-label="切换精选影片">
      <span aria-live="polite">${String(featuredIndex + 1).padStart(2, '0')}<span class="hero-slash">/</span>${String(featuredIds.length).padStart(2, '0')}</span>
      <button class="icon-button" type="button" aria-label="上一部精选" data-action="featured-prev" data-tv>${icon('prev')}</button>
      <button class="icon-button" type="button" aria-label="下一部精选" data-action="featured-next" data-tv>${icon('next')}</button>
    </div>
  </div>`;
}

function renderHome() {
  root.innerHTML = `<div id="hero-slot">${hero()}</div>
    <div id="watching-slot"></div>
    <section class="shelf" aria-labelledby="open-heading">
      <div class="section-head">
        <div><h2 id="open-heading">开放短片精选</h2><p>剧情短片与迷你系列</p></div>
        <a class="text-link" href="#discover" data-tv>全部影片</a>
      </div>
      ${shelf(catalog.slice(0, 6))}
    </section>`;
  renderDynamicShelves();
}

function inProgress() {
  return catalog.filter(({ id, episodes }) => {
    const entry = state.progress[id];
    return entry && (!entry.ended || entry.episode < episodes.length);
  }).sort((a, b) => state.progress[b.id].updated - state.progress[a.id].updated);
}

function renderDynamicShelves() {
  if (activePage === 'library') {
    const library = document.querySelector('#library-content');
    if (!library) return;
    const saved = [...state.saved].reverse().map((id) => byId.get(id));
    library.innerHTML = `<section class="shelf"><div class="section-head"><h2>已收藏</h2></div>
      ${saved.length ? shelf(saved) : emptyState('bookmark', '片单还是空的', '收藏想看的影片，它们会出现在这里。', '浏览片库')}</section>
      <section class="shelf"><div class="section-head"><h2>继续观看</h2></div>
      ${inProgress().length ? shelf(inProgress(), true) : emptyState('film', '暂无观看进度', '播放后，你可以从上次的位置继续。')}</section>`;
  }
  if (activePage === 'home') {
    const watching = document.querySelector('#watching-slot');
    const shows = inProgress();
    if (watching) {
      watching.innerHTML = shows.length ? `<section class="shelf"><div class="section-head"><h2>继续观看</h2></div>${shelf(shows, true)}</section>` : '';
    }
  }
}

function emptyState(mark, title, text, action) {
  return `<div class="empty-state"><span>${icon(mark)}</span><h3>${title}</h3><p>${text}</p>${action ? `<a href="#discover" class="button secondary" data-tv>${action}</a>` : ''}</div>`;
}

function renderDiscover() {
  root.innerHTML = `<div class="page-heading"><h1>片库</h1><p>按题材找到想看的故事。</p></div>
    <div class="filters" aria-label="按题材筛选">${['全部', ...genres].map((genre) => `<button class="filter" data-action="genre" data-genre="${genre}" aria-pressed="${genre === activeGenre}" data-tv>${genre}</button>`).join('')}</div>
    <div id="discover-results"></div>`;
  renderDiscoverResults();
}

function renderDiscoverResults() {
  const shows = activeGenre === '全部' ? catalog : catalog.filter((show) => show.genres.includes(activeGenre));
  document.querySelector('#discover-results').innerHTML = `<p class="result-count" role="status">${shows.length} 部影片</p>${shelf(shows)}`;
}

function renderSearch() {
  root.innerHTML = `<div class="page-heading"><h1>搜索</h1><p>按片名、题材或出品方搜索。</p></div>
    <div class="search-field">${icon('search')}<label class="sr-only" for="catalog-search">搜索影片</label><input id="catalog-search" type="search" placeholder="例如：钢铁之泪、科幻、Blender" autocomplete="off"></div>
    <div id="search-results"></div>`;
  const input = document.querySelector('#catalog-search');
  input.value = searchQuery;
  input.addEventListener('input', () => {
    searchQuery = input.value;
    renderSearchResults();
  });
  renderSearchResults();
}

function renderSearchResults() {
  const terms = searchQuery.toLowerCase().trim().split(/\s+/).filter(Boolean);
  const shows = catalog.filter((show) => {
    const text = [show.title, show.original, show.credit, show.description, ...show.genres].join(' ').toLowerCase();
    return terms.every((term) => text.includes(term));
  });
  document.querySelector('#search-results').innerHTML = `<p class="result-count" role="status">${terms.length ? `找到 ${shows.length} 部影片` : '全部影片'}</p>
    ${shows.length ? shelf(shows) : emptyState('search', '没有找到影片', '试试其他片名或题材。')}`;
}

function creditLinks(show) {
  const episodeCredits = show.episodes.filter((episode) => episode.credit);
  return `<div class="credit-links"><p>${show.credit}</p>
    <a href="${show.source}" target="_blank" rel="noopener noreferrer">出品方出处</a>
    ${show.licenseUrl ? `<a href="${show.licenseUrl}" target="_blank" rel="noopener noreferrer">${show.license}</a>` : `<span>${show.license}</span>`}
    ${show.repository ? `<a href="${show.repository}" target="_blank" rel="noopener noreferrer">GitHub 片源</a>` : ''}
    ${show.changes ? `<small>${show.changes}</small>` : ''}
    ${episodeCredits.length ? `<details><summary>各集署名与许可</summary><ul>${episodeCredits.map((episode) => `<li><a href="${episode.source}" target="_blank" rel="noopener noreferrer">${episode.title} · ${episode.license}</a><p>${episode.credit}</p></li>`).join('')}</ul></details>` : ''}</div>`;
}

function renderSources() {
  root.innerHTML = `<div class="page-heading"><h1>片源与授权</h1><p>从 GitHub 发现开放作品，按出品方公布的许可收录。所有影片通过媒体直链播放。</p></div>
    <section class="shelf sources-section"><div class="section-head"><h2>GitHub 仓库</h2></div>
    <ul class="source-list">${repositories.map((repo) => `<li><a href="${repo.url}" target="_blank" rel="noopener noreferrer" data-tv>${repo.name}</a><p>${repo.description}</p></li>`).join('')}</ul></section>
    <section class="shelf sources-section"><div class="section-head"><h2>影片署名</h2></div>
    <ul class="source-list">${catalog.map((show) => `<li><h3>${show.title} <span>${show.original}</span></h3>${creditLinks(show)}</li>`).join('')}</ul></section>`;
}

function renderPage({ focus = false } = {}) {
  const route = location.hash.slice(1);
  const previousPage = activePage;
  activePage = Object.hasOwn(routes, route) ? route : 'home';
  document.querySelector('#page-label').textContent = routes[activePage];
  document.title = `${routes[activePage]} · Tom短剧`;
  document.querySelectorAll('[data-route]').forEach((link) => {
    if (link.dataset.route === activePage) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  });
  switch (activePage) {
    case 'discover': renderDiscover(); break;
    case 'search': renderSearch(); break;
    case 'library':
      root.innerHTML = '<div class="page-heading"><h1>我的片单</h1><p>收藏和观看进度保存在当前浏览器。</p></div><div id="library-content"></div>';
      renderDynamicShelves();
      break;
    case 'sources': renderSources(); break;
    default: renderHome();
  }
  if (!focus || previousPage === activePage) return;
  window.scrollTo(0, 0);
  (activePage === 'search' ? document.querySelector('#catalog-search') : root).focus({ preventScroll: true });
}

function openDetail(show, trigger) {
  detailTrigger = trigger;
  detailShow = show;
  const continuing = state.progress[show.id] && !state.progress[show.id].ended;
  detail.innerHTML = `<div class="detail-art" ${posterStyle(show)}>
      <img src="${show.hero || show.image}" alt="" width="900" height="450">
      ${closeButton}
      <div class="detail-title"><h2 id="detail-title">${show.title}</h2><p>${show.original}</p></div>
    </div>
    <div class="detail-body">
      <div class="title-meta">${show.year ? `<span>${show.year}</span>` : ''}${show.genres.map((genre) => `<span>${genre}</span>`).join('')}<span>${show.episodes.length === 1 ? show.length : `${show.episodes.length} 集`}</span>${show.episodes[0].tracks ? '<span>中文字幕</span>' : ''}</div>
      <p class="detail-description">${show.description}</p>
      <div class="actions">${playButton(show, continuing ? '继续观看' : '立即播放')}${saveButton(show)}</div>
      <section class="episode-section"><h3>${show.episodes.length > 1 ? '选集' : '正片'}</h3>
      ${show.episodes.map((episode, index) => `<button class="detail-episode" type="button" data-action="play-episode" data-id="${show.id}" data-episode="${index + 1}" data-tv>${icon('play')}<span>${show.episodes.length > 1 ? `第 ${index + 1} 集 · ` : ''}${episode.title}</span><small>${episode.durationLabel || ''}</small></button>`).join('')}
      </section>
      ${creditLinks(show)}
    </div>`;
  detail.showModal();
}

function openPlayer(show, selectedEpisode) {
  const stored = state.progress[show.id];
  const nextEpisode = stored?.ended ? Number(stored.episode) + 1 : Number(stored?.episode) || 1;
  const episode = selectedEpisode || (nextEpisode <= show.episodes.length ? nextEpisode : 1);
  const resume = !stored?.ended && stored?.episode === episode ? stored.seconds : 0;
  document.querySelector('#player-credits').innerHTML = creditLinks(show);
  player.open(show, episode, resume);
}

function notify(message) {
  const toast = document.querySelector('#toast');
  toast.textContent = message;
  toast.classList.add('visible');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('visible'), 2500);
}

function toggleSaved(show) {
  const saved = !state.saved.has(show.id);
  if (saved) state.saved.add(show.id);
  else state.saved.delete(show.id);
  persist();
  if (activePage === 'library') {
    const savedShelf = document.querySelector('#library-content');
    const focusRemoved = savedShelf?.contains(document.activeElement);
    renderDynamicShelves();
    if (focusRemoved && !detail.open) {
      (savedShelf.querySelector('[data-tv]') || root).focus({ preventScroll: true });
    }
  }
  document.querySelectorAll(`[data-action="save"][data-id="${show.id}"]`).forEach((button) => {
    button.setAttribute('aria-pressed', String(saved));
    if (button.classList.contains('mini-save')) {
      button.setAttribute('aria-label', `${saved ? '取消收藏' : '收藏'} ${show.title}`);
      button.title = saved ? '取消收藏' : '收藏';
      button.innerHTML = icon(saved ? 'check' : 'plus');
    } else {
      button.innerHTML = `${icon(saved ? 'check' : 'plus')}${saved ? '已收藏' : '加入片单'}`;
    }
  });
  notify(saved ? '已加入片单' : '已移出片单');
}

document.addEventListener('click', (event) => {
  const button = event.target.closest('button[data-action]');
  if (!button) return;
  const action = button.dataset.action;
  const show = byId.get(button.dataset.id);
  if (action === 'genre') {
    activeGenre = button.dataset.genre;
    document.querySelectorAll('.filter').forEach((filter) => filter.setAttribute('aria-pressed', String(filter === button)));
    renderDiscoverResults();
  } else if (action === 'featured-prev' || action === 'featured-next') {
    const direction = action === 'featured-next' ? 1 : -1;
    featuredIndex = (featuredIndex + direction + featuredIds.length) % featuredIds.length;
    const slot = document.querySelector('#hero-slot');
    slot.innerHTML = hero();
    slot.querySelector(`[data-action="${action}"]`).focus({ preventScroll: true });
  } else if (show && action === 'detail') {
    openDetail(show, button);
  } else if (show && (action === 'play' || action === 'play-episode')) {
    openPlayer(show, Number(button.dataset.episode) || undefined);
  } else if (show && action === 'save') {
    toggleSaved(show);
  }
});

detail.addEventListener('click', (event) => {
  if (event.target === detail || event.target.closest('[data-close-detail]')) detail.close();
});
detail.addEventListener('close', () => {
  if (detailTrigger?.isConnected) detailTrigger.focus({ preventScroll: true });
  else if (detailShow) {
    (root.querySelector(`[data-action="detail"][data-id="${detailShow.id}"]`) || root).focus({ preventScroll: true });
  }
});
window.addEventListener('pagehide', persist);
window.addEventListener('hashchange', () => {
  if (location.hash !== '#app-view') renderPage({ focus: true });
});

document.addEventListener('keydown', (event) => {
  if (event.key === '/' && !event.altKey && !event.ctrlKey && !event.metaKey && !event.target.matches('input, textarea, video') && !detail.open && !playerDialog.open) {
    event.preventDefault();
    if (activePage === 'search') document.querySelector('#catalog-search').focus();
    else location.hash = 'search';
    return;
  }
  const direction = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
  if (!direction || event.altKey || event.ctrlKey || event.metaKey || !event.target.matches('[data-tv]') || playerDialog.open) return;
  const origin = event.target.getBoundingClientRect();
  const axis = direction[0] ? 'x' : 'y';
  const cross = axis === 'x' ? 'y' : 'x';
  const center = (rect, key) => key === 'x' ? rect.x + rect.width / 2 : rect.y + rect.height / 2;
  const scope = detail.open ? detail : document;
  let best;
  let bestScore = Infinity;
  for (const candidate of scope.querySelectorAll('[data-tv]')) {
    if (candidate === event.target || candidate.closest('dialog:not([open])') || !candidate.getClientRects().length) continue;
    const rect = candidate.getBoundingClientRect();
    const forward = (center(rect, axis) - center(origin, axis)) * (direction[0] || direction[1]);
    const side = Math.abs(center(rect, cross) - center(origin, cross));
    if (forward <= 5 || side > Math.max(44, forward * 1.6)) continue;
    const score = forward + side * 3;
    if (score < bestScore) {
      bestScore = score;
      best = candidate;
    }
  }
  if (!best) return;
  event.preventDefault();
  best.focus();
});

renderPage();
