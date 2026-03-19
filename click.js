function click(time) {
  const [H, M, S] = time.split(':');
  const d = new Date();
  const target = new Date(d.getFullYear(), d.getMonth(), d.getDate(), +H, +M, +S).getTime();
  if (target <= Date.now()) { console.error('In the past'); return; }

  const btn = [...document.querySelectorAll('.FlatButton__content')]
    .find(el => el.textContent.trim() === 'Post');
  if (!btn) { console.error('Button not found'); return; }

  console.log(`[*] Click at ${time} (in ${((target - Date.now()) / 1000).toFixed(1)}s)`);

  setTimeout(() => {
    const wait = () => {
      if (Date.now() >= target) { btn.click(); console.log(`[*] Clicked at ${new Date().toLocaleTimeString()}`); }
      else requestAnimationFrame(wait);
    };
    requestAnimationFrame(wait);
  }, target - Date.now() - 2000);
}
