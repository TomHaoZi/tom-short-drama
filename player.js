export function createPlayer({ dialog, onProgress = () => {}, onClose = () => {} }) {
  const title = dialog.querySelector('[data-player-title]');
  const episodeLabel = dialog.querySelector('[data-player-episode-label]');
  const video = dialog.querySelector('[data-player-video]');
  const playlist = dialog.querySelector('[data-player-list]');
  const error = dialog.querySelector('[data-player-error]');
  const closeButton = dialog.querySelector('[data-player-close]');
  const isList = playlist.matches('ol, ul');
  let show;
  let selection;
  let episodeButtons = [];
  let restoreFocus;
  let pressedBackdrop = false;

  video.controls = true;
  video.playsInline = true;
  video.preload = 'metadata';

  function setError(message = '') {
    error.textContent = message;
    error.hidden = !message;
  }

  function reportProgress(ended = video.ended) {
    if (!selection || video.readyState < 1 || !Number.isFinite(video.duration) || video.duration <= 0) return;

    const seconds = ended ? video.duration : video.currentTime;
    selection.lastPosition = seconds;
    const wholeSeconds = Math.floor(seconds);
    if (selection.lastSecond === wholeSeconds && selection.ended === ended) return;

    selection.lastSecond = wholeSeconds;
    selection.ended = ended;
    onProgress(show.id, selection.number, seconds, video.duration, ended);
  }

  function startPlayback() {
    // Some browsers defer playback until the viewer uses the native play control.
    video.play().catch(() => {});
  }

  function loadSource(src) {
    video.src = src;
    video.load();
    startPlayback();
  }

  function setTracks(tracks = []) {
    const elements = tracks.filter(track => track.src && track.srclang).map(track => {
      const element = document.createElement('track');
      element.kind = 'subtitles';
      element.src = track.src;
      element.srclang = track.srclang;
      element.label = track.label || track.srclang;
      element.default = Boolean(track.default);
      return element;
    });
    video.replaceChildren(...elements);
  }

  function currentPosition() {
    if (selection.resumeSeconds !== null) return selection.resumeSeconds;
    if (video.readyState >= 1) return video.currentTime;
    return selection.lastPosition;
  }

  function selectEpisode(number, resumeSeconds = 0) {
    const episode = show.episodes[number - 1];
    if (!episode) return;

    const isCurrent = selection?.number === number;
    if (isCurrent && error.hidden) {
      startPlayback();
      return;
    }

    const position = isCurrent ? currentPosition() : resumeSeconds;
    const src = episode.src || episode.fallbackSrc;
    reportProgress();
    selection = {
      number,
      resumeSeconds: position,
      lastPosition: position,
      lastSecond: -1,
      ended: false,
      usedFallback: src === episode.fallbackSrc,
    };
    episodeLabel.textContent = episode.title ? `第 ${number} 集 · ${episode.title}` : `第 ${number} 集`;
    for (const button of episodeButtons) button.removeAttribute('aria-current');
    episodeButtons[number - 1].setAttribute('aria-current', 'true');
    setError();
    setTracks(episode.tracks);

    const poster = episode.poster || show.image;
    if (poster) video.poster = poster;
    else video.removeAttribute('poster');

    if (!src) {
      video.removeAttribute('src');
      video.load();
      setError('本集暂无播放源，请选择其他集。');
      return;
    }

    loadSource(src);
  }

  function renderPlaylist() {
    episodeButtons = show.episodes.map((episode, index) => {
      const number = index + 1;
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'player-episode';

      const episodeNumber = document.createElement('span');
      episodeNumber.className = 'player-episode-number';
      episodeNumber.textContent = `第 ${number} 集`;
      button.append(episodeNumber);

      if (episode.title) {
        const episodeTitle = document.createElement('span');
        episodeTitle.className = 'player-episode-title';
        episodeTitle.textContent = episode.title;
        button.append(episodeTitle);
      }

      if (episode.durationLabel) {
        const duration = document.createElement('span');
        duration.className = 'player-episode-duration';
        duration.textContent = episode.durationLabel;
        button.append(duration);
      }

      button.addEventListener('click', () => selectEpisode(number));
      return button;
    });

    playlist.replaceChildren(...episodeButtons.map(button => {
      if (!isList) return button;
      const listItem = document.createElement('li');
      listItem.append(button);
      return listItem;
    }));
  }

  function open(nextShow, episodeNumber = 1, resumeSeconds = 0) {
    if (!dialog.open) restoreFocus = document.activeElement;
    reportProgress();
    selection = undefined;
    show = nextShow;
    title.textContent = show.title;
    renderPlaylist();
    if (!dialog.open) dialog.showModal();
    closeButton.focus({ preventScroll: true });

    if (!show.episodes.length) {
      episodeLabel.textContent = '';
      video.removeAttribute('src');
      video.removeAttribute('poster');
      setTracks();
      video.load();
      setError('暂无可播放剧集。');
      return;
    }

    const number = show.episodes[episodeNumber - 1] ? Number(episodeNumber) : 1;
    const resume = number === Number(episodeNumber) && Number.isFinite(resumeSeconds) ? resumeSeconds : 0;
    selectEpisode(number, resume);
    episodeButtons[number - 1].scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }

  video.addEventListener('loadedmetadata', () => {
    if (!selection) return;
    const seconds = selection.resumeSeconds;
    selection.resumeSeconds = null;
    if (seconds > 0 && seconds < video.duration) video.currentTime = seconds;
    reportProgress();
  });
  video.addEventListener('timeupdate', () => reportProgress());
  video.addEventListener('seeked', () => reportProgress());
  video.addEventListener('error', () => {
    if (!dialog.open || !selection || !video.error) return;

    const { fallbackSrc } = show.episodes[selection.number - 1];
    if (fallbackSrc && !selection.usedFallback) {
      selection.resumeSeconds = currentPosition();
      selection.usedFallback = true;
      loadSource(fallbackSrc);
      return;
    }

    setError('暂时无法播放，请重新点选本集或切换其他集。');
  });
  video.addEventListener('ended', () => {
    if (!selection || !video.ended) return;
    reportProgress(true);
    const nextNumber = selection.number + 1;
    if (!show.episodes[nextNumber - 1]) return;
    selectEpisode(nextNumber);
    episodeButtons[nextNumber - 1].scrollIntoView({ block: 'nearest', inline: 'nearest' });
  });

  function isBackdrop(event) {
    const bounds = dialog.getBoundingClientRect();
    return event.target === dialog && (
      event.clientX < bounds.left || event.clientX > bounds.right ||
      event.clientY < bounds.top || event.clientY > bounds.bottom
    );
  }

  closeButton.addEventListener('click', event => {
    event.preventDefault();
    dialog.close();
  });
  dialog.addEventListener('pointerdown', event => {
    pressedBackdrop = isBackdrop(event);
  });
  dialog.addEventListener('click', event => {
    if (pressedBackdrop && isBackdrop(event)) dialog.close();
    pressedBackdrop = false;
  });
  dialog.addEventListener('close', () => {
    if (dialog.open) return;
    reportProgress();
    selection = undefined;
    show = undefined;
    video.pause();
    video.removeAttribute('src');
    video.removeAttribute('poster');
    setTracks();
    video.load();
    onClose();
    if (restoreFocus?.isConnected) restoreFocus.focus({ preventScroll: true });
  });

  setError();
  return { open };
}
