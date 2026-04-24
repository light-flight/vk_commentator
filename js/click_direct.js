function click(time) {
  const [H, M, S] = time.split(':');
  const d = new Date();
  const t = new Date(d.getFullYear(), d.getMonth(), d.getDate(), +H, +M, +S).getTime();
  const btn = [...document.querySelectorAll('.FlatButton__content')].find(e => e.textContent.trim() === 'Post');
  const p = performance, tt = t - p.timeOrigin;
  setTimeout(() => { while (p.now() < tt) {} btn.click(); }, Math.max(0, t - Date.now() - 50));
}
