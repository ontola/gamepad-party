#!/bin/sh
# Turn footage/<name>.mp4 into numbered frames f/<name>/NNN.jpg (30 fps) and
# write f/counts.js with the number of frames per clip for compose.html.
set -e
cd "$(dirname "$0")"
rm -rf f && mkdir -p f
echo 'window.COUNTS = {' > f/counts.js
for clip in footage/*.mp4; do
  name=$(basename "$clip" .mp4)
  mkdir -p "f/$name"
  ffmpeg -v error -y -i "$clip" -vf "fps=30,scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080" -q:v 3 "f/$name/%03d.jpg"
  echo "  '$name': $(ls "f/$name" | wc -l)," >> f/counts.js
done
echo '};' >> f/counts.js
cat f/counts.js
