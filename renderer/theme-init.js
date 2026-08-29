(() => {
  const preference = localStorage.getItem('kaki-theme')
  const theme = ['system', 'light', 'dark'].includes(preference) ? preference : 'system'
  const resolved = theme === 'system'
    ? (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')
    : theme

  document.documentElement.dataset.themePreference = theme
  document.documentElement.dataset.theme = resolved
  document.documentElement.style.colorScheme = resolved
})()
