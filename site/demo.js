const stage = document.querySelector('.demo .stage');

if (stage && window.matchMedia('(prefers-reduced-motion: no-preference)').matches) {
  const start = () => stage.classList.add('is-playing');

  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting || entry.intersectionRatio < 0.6) return;
      observer.disconnect();
      start();
    }, { threshold: 0.6 });
    observer.observe(stage);
  } else {
    start();
  }
}
