function click(time) {
  const [H, M, S] = time.split(':');
  const d = new Date();
  const t = new Date(d.getFullYear(), d.getMonth(), d.getDate(), +H, +M, +S).getTime();
  const el = [...document.querySelectorAll('.FlatButton__content')].find(e => e.textContent.trim() === 'Post');
  const btn = (el.closest('button,[role="button"]') || el);
  const evt = new MouseEvent('click', { bubbles: true, cancelable: true, view: window });
  const code = `self.onmessage=e=>{const t=e.data,o=performance.timeOrigin;setTimeout(()=>{while(o+performance.now()<t){}self.postMessage(null)},Math.max(0,t-o-performance.now()-50))}`;
  const w = new Worker(URL.createObjectURL(new Blob([code], { type: 'application/javascript' })));
  w.onmessage = () => btn.dispatchEvent(evt);
  w.postMessage(t - 1);
}
