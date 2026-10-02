// Applies the remembered theme before first paint (classic script in <head>, so no flash). "system" = no attribute.
(function () {
  try {
    var v = JSON.parse(localStorage.getItem('desk.theme'));
    if (v === 'light' || v === 'dark') document.documentElement.setAttribute('data-theme', v);
  } catch (e) { /* storage unavailable: follow the system */ }
})();
