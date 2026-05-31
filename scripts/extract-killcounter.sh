#!/bin/bash
# Helper to extract Fortnite kill counter using confirmed region

VIDEO="$1"
OUT="$2"
CROP_WIDTH=20
CROP_HEIGHT=20
CROP_X=1200
CROP_Y=211

ffmpeg -hide_banner -loglevel error -y -i "$VIDEO" -vf "crop=${CROP_WIDTH}:${CROP_HEIGHT}:${CROP_X}:${CROP_Y}" -frames:v 1 "$OUT"

# Enhance the crop for better OCR (resize, sharpen, contrast)
source /workspaces/vidcom/.venv/bin/activate
python3 -c "from PIL import Image, ImageEnhance, ImageFilter; im=Image.open('$OUT'); im=im.resize((40,40),Image.LANCZOS).filter(ImageFilter.SHARPEN); im=ImageEnhance.Contrast(im).enhance(2.0); im.save('$OUT')"
