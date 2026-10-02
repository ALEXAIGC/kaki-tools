window.kaki.getSettings().then(data => {
  document.getElementById('app-version').textContent = `版本 v${data.version}`
})
