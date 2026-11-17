#!/bin/sh
# Shekel fork. Run from the repo root inside the rails container:
#   sh docs/shekel/generate_brand_icons.sh
# Regenerates Chatwoot's PNG icons from the official Shekel Mobility mark,
# keeping each file's existing pixel size.
set -e
SRC=public/brand-assets/logo_thumbnail.svg
render() { # size pad_pct bg out
  size=$1; inner=$(( size * (100 - 2 * $2) / 100 ))
  magick -background none -density 1200 "$SRC" -resize "${inner}x${inner}" \
    -background "$3" -gravity center -extent "${size}x${size}" -strip "$4"
}
for f in public/favicon-16x16.png public/favicon-32x32.png public/favicon-96x96.png public/favicon-512x512.png \
         public/android-icon-*.png public/ms-icon-*.png; do
  s=$(magick identify -format '%w' "$f"); render "$s" 4 none "$f"; echo "$f $s"
done
for f in public/apple-icon*.png public/apple-touch-icon*.png; do
  s=$( [ -s "$f" ] && magick identify -format "%w" "$f" || echo 180 ); render "$s" 14 '#181918' "$f"; echo "$f $s (dark canvas)"
done
# Unread badge: the mark with a red dot (top right) and a transparent knock-out ring, as upstream.
for s in 16 32 96; do
  f=public/favicon-badge-${s}x${s}.png
  render "$s" 4 none /tmp/base.png
  r=$(( s * 22 / 100 )); ring=$(( r + s * 6 / 100 )); cx=$(( s - r - 1 )); cy=$(( r + 1 ))
  magick /tmp/base.png \
    \( -size ${s}x${s} xc:none -fill black -draw "circle $cx,$cy $((cx + ring)),$cy" \) \
    -compose DstOut -composite -compose Over \
    -fill '#FF3B30' -draw "circle $cx,$cy $((cx + r)),$cy" -strip "$f"
  echo "$f $s (badge)"
done
