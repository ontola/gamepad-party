// Marks phones and tablets before the page paints, so the homepage can lead
// with installing the app there instead of hosting (which needs a TV screen).
(()=>{
  const ua=navigator.userAgent;
  const phone=/Android/i.test(ua)?'android':(/iPhone|iPad|iPod/.test(ua)||(/Macintosh/.test(ua)&&navigator.maxTouchPoints>1))?'ios':'';
  if(phone)document.documentElement.dataset.phone=phone;
})();
