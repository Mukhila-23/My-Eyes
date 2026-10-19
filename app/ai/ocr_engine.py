import os
import logging

import cv2
import easyocr

# Load the OCR model once when the application starts
logger = logging.getLogger("myeyes.ocr")

# Initialize once, rather than on every scan.  The API layer logs request
# stages so a slow/failed OCR call can be distinguished from upload or TTS.
reader = easyocr.Reader(
    ['en'],
    gpu=False
)

# Largest edge length handed to EasyOCR.  Bigger input only slows CPU
# inference without helping accuracy (see extract_text).  Measured on a CPU
# server: ~12s at 1280px, ~27s at 1600px, ~45s at 2000px; the app's request
# timeout is 90s, so 1600 keeps every scan comfortably inside the budget.
_MAX_OCR_DIMENSION = 1600
# Currency notes are enhanced and, if smaller than this, upscaled so the
# fine denomination print reaches the recognizer.
_ENHANCE_MIN_DIMENSION = 1200


class OcrUnavailableError(RuntimeError):
    """The OCR model itself failed.

    Raised instead of returning an empty string so callers that must not
    report a model failure as "nothing found" (currency detection) can tell
    the two cases apart.
    """


def _prepare_image(image_path: str, enhance: bool):
    """Decode and preprocess one image for recognition.

    Returns ``None`` when the file is missing, empty or undecodable.
    """
    # EasyOCR/OpenCV otherwise raises `!ssize.empty()` for a corrupt image or
    # an invalid internal crop.  The API has already validated uploads, but
    # keep this boundary defensive for every caller.
    #
    # EasyOCR also runs its text detector over the whole frame, so a
    # full-resolution phone photo (3000-4000 px) can take minutes on a CPU --
    # enough for the app's request timeout to hit and leave the user stuck on
    # "Processing...".  Every image is capped before recognition instead, which
    # keeps a scan bounded while still resolving the text a phone can capture.
    if not os.path.isfile(image_path) or os.path.getsize(image_path) == 0:
        logger.warning("OCR skipped: missing or empty image path=%s", image_path)
        return None
    image = cv2.imread(image_path)
    if image is None or image.size == 0 or min(image.shape[:2]) < 2:
        logger.warning("OCR skipped: undecodable image path=%s", image_path)
        return None

    height, width = image.shape[:2]
    max_dim = max(height, width)

    if enhance:
        # Currency notes carry their denomination in small printed digits and
        # words.  Crop-less preprocessing: clamp huge uploads first, then boost
        # contrast and upscale small notes so the recognizer can read them.
        if max_dim > _MAX_OCR_DIMENSION:
            scale = _MAX_OCR_DIMENSION / float(max_dim)
            image = cv2.resize(
                image,
                (int(width * scale), int(height * scale)),
                interpolation=cv2.INTER_AREA,
            )
            logger.info(
                "OCR DOWNSCALED path=%s %dx%d -> %dx%d",
                image_path, width, height,
                image.shape[1], image.shape[0],
            )
            height, width = image.shape[:2]
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        image = clahe.apply(gray)
        height, width = image.shape[:2]
        if max(height, width) < _ENHANCE_MIN_DIMENSION:
            scale = _ENHANCE_MIN_DIMENSION / float(max(height, width))
            image = cv2.resize(
                image,
                (int(width * scale), int(height * scale)),
                interpolation=cv2.INTER_CUBIC,
            )
            logger.info(
                "OCR ENHANCED path=%s upscaled to %dx%d",
                image_path, image.shape[1], image.shape[0],
            )
    elif max_dim > _MAX_OCR_DIMENSION:
        scale = _MAX_OCR_DIMENSION / float(max_dim)
        image = cv2.resize(
            image,
            (int(width * scale), int(height * scale)),
            interpolation=cv2.INTER_AREA,
        )
        logger.info(
            "OCR DOWNSCALED path=%s %dx%d -> %dx%d",
            image_path, width, height,
            image.shape[1], image.shape[0],
        )

    return image


def _box_height(box) -> float:
    """Height in pixels of one EasyOCR quadrilateral."""
    try:
        ys = [float(point[1]) for point in box]
    except (TypeError, ValueError, IndexError):
        return 0.0
    if len(ys) < 2:
        return 0.0
    return max(ys) - min(ys)


def read_text_results(image_path: str, *, enhance: bool = False) -> list:
    """Recognize text and return one entry per detected text box.

    Each entry is ``{"text", "box", "height", "confidence"}``.  Callers that
    need to judge *how* something was printed (currency detection compares the
    size of the denomination against the note's serial print) use this instead
    of :func:`extract_text`.

    Raises :class:`OcrUnavailableError` when the recognizer fails.
    """
    logger.info("OCR START path=%s enhance=%s", image_path, enhance)
    image = _prepare_image(image_path, enhance)
    if image is None:
        return []

    try:
        raw = reader.readtext(image)
    except (cv2.error, RuntimeError, ValueError) as exc:
        logger.error("OCR failed path=%s error=%s", image_path, exc)
        raise OcrUnavailableError(str(exc)) from exc

    results = []
    for item in raw:
        # EasyOCR detail=1 rows are [[quadrilateral, text, confidence], ...].
        if not item or len(item) < 2:
            continue
        box = item[0]
        text = (item[1] or "").strip()
        if not text:
            continue
        confidence = 0.0
        if len(item) > 2 and isinstance(item[2], (int, float)):
            confidence = float(item[2])
        results.append({
            "text": text,
            "box": box,
            "height": _box_height(box),
            "confidence": confidence,
        })

    logger.info(
        "OCR COMPLETED path=%s boxes=%d characters=%d",
        image_path, len(results), sum(len(r["text"]) for r in results),
    )
    return results


def extract_text(image_path: str, *, enhance: bool = False) -> str:
    """
    Extract text from an image using EasyOCR.

    `enhance` applies note-oriented preprocessing (contrast + upscale) used by
    currency detection; regular text OCR keeps the fast path.
    """
    try:
        results = read_text_results(image_path, enhance=enhance)
    except OcrUnavailableError as exc:
        logger.warning("OCR unavailable path=%s error=%s", image_path, exc)
        return ""

    return "\n".join(result["text"] for result in results)
