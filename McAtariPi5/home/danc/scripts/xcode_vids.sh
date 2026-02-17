#!/bin/bash

for f in *.mp4; do
  ffmpeg -i "$f" \
    -map 0:v:0 -map 0:a? \
    -c:v libx264 -profile:v baseline -level 3.0 -pix_fmt yuv420p \
    -c:a aac -b:a 128k \
    -movflags +faststart \
    "fixed_$f"
done
echo "Conversion complete!"