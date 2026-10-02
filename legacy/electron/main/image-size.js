// Bound both dimensions without enlarging small images.
function fitImage(width, height, maxWidth, maxHeight) {
  const scale = Math.min(1, maxWidth / Math.max(1, width), maxHeight / Math.max(1, height))
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) }
}
module.exports = { fitImage }
