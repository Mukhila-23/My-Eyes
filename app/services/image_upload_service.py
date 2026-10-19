"""One safe image-upload path shared by every vision module."""

import os
import uuid

import cv2
import numpy as np
from fastapi import HTTPException, UploadFile

UPLOAD_FOLDER = "app/uploads"
MAX_IMAGE_BYTES = 15 * 1024 * 1024
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}


def save_validated_image(file: UploadFile) -> tuple[str, str]:
    """Validate bytes before any OCR/model call, then persist the image."""
    extension = os.path.splitext(file.filename or "")[1].lower()
    if extension not in ALLOWED_EXTENSIONS:
        raise HTTPException(400, "Please upload a JPG, PNG, WebP, or BMP image.")

    data = file.file.read(MAX_IMAGE_BYTES + 1)
    if not data:
        raise HTTPException(400, "The uploaded image is empty.")
    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(400, "The uploaded image is too large.")

    image = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None or image.size == 0:
        raise HTTPException(400, "The uploaded file is not a readable image.")
    height, width = image.shape[:2]
    if height < 2 or width < 2:
        raise HTTPException(400, "The uploaded image is too small to process.")

    os.makedirs(UPLOAD_FOLDER, exist_ok=True)
    filename = f"{uuid.uuid4()}{extension}"
    path = os.path.join(UPLOAD_FOLDER, filename)
    with open(path, "wb") as output:
        output.write(data)
    return filename, path
