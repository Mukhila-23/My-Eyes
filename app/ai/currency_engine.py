import logging
import re

from app.ai.ocr_engine import OcrUnavailableError, read_text_results


logger = logging.getLogger("myeyes.currency")

# This repository does not configure a trained currency-classification model.
# Denominations are resolved from what EasyOCR actually reads on the uploaded
# image (see _log_model_state).  Only return a denomination when the recognized
# text carries real currency evidence, never an arbitrary number such as a note
# serial number or a price.
SUPPORTED_DENOMINATIONS = (10, 20, 50, 100, 200, 500)

# Indian notes print their denomination as a large standalone number plus
# words/markers such as "RESERVE BANK OF INDIA".  A bare denomination number is
# only accepted as evidence when one of these markers is also present, which
# prevents a serial number or a price from being misread as a denomination.
NOTE_MARKERS = (
    "INDIA",
    "RESERVE",
    "RUPEE",
    "RUPEES",
    "GANDHI",
    "RBI",
    "BHARAT",
    "SPMG",
    "₹",
)

# A printed "₹100" / "Rs. 100" / "RUPEES 100" is the strongest evidence.
#
# EasyOCR renders the ₹ glyph as the letter "r" or "R" on real note photos
# (observed on this app's own uploads: "r100", "r200"), so that variant is
# accepted too -- but only when the note markers corroborate it, because a
# lone "R" is ambiguous and could be any letter in ordinary text.
_RUPEE_NUMBER = re.compile(
    r"^(?:₹|RS|RUPEE|RUPEES|R)\s*[.:\-]?\s*([0-9]{1,3})$"
)
# Confirms the ambiguous single-letter variant above.
_AMBIGUOUS_RUPEE = re.compile(r"^R\s*[.:\-]?\s*[0-9]{1,3}$")

# The denomination also appears in words, e.g. "ONE HUNDRED RUPEES".
_WORD_DENOMINATION = {
    500: r"\bFIVE\s+HUNDRED\b",
    200: r"\bTWO\s+HUNDRED\b",
    100: r"\bONE\s+HUNDRED\b",
    50: r"\bFIFTY\b",
    20: r"\bTWENTY\b",
    10: r"\bTEN\b",
}
# "... RUPEES" next to the number in words is itself a currency marker.
_WORD_WITH_CURRENCY = r"\bRUPEES?\b"

# Base confidence per evidence tier.  The recognizer's own score only refines
# it; it can never promote a tier, so weak text never becomes a confident
# answer.  The tiers stay conservative because EasyOCR scores stylized note
# glyphs low even when it reads them correctly (observed ~0.35-0.50).
_TIER_BASE_CONFIDENCE = {1: 0.90, 2: 0.85, 3: 0.70}

_model_state_logged = False


def _log_model_state() -> None:
    """Record, once, what actually performs currency recognition."""
    global _model_state_logged
    if _model_state_logged:
        return
    _model_state_logged = True
    logger.info("[Currency] Model loaded: none (no trained currency model exists)")
    logger.info("[Currency] Model task: none - detection is OCR-based")
    logger.info("[Currency] Model classes: not applicable")
    logger.info(
        "[Currency] Supported denominations: %s",
        ", ".join(str(value) for value in SUPPORTED_DENOMINATIONS),
    )


def detect_currency(image_path: str) -> dict:
    """Return a denomination only when the uploaded image has evidence."""
    _log_model_state()
    logger.info("[Currency] Backend inference started path=%s", image_path)

    # enhance=True runs the note-oriented OCR path (contrast + upscale) so the
    # small denomination print on Indian notes has a fair chance of being read.
    try:
        boxes = read_text_results(image_path, enhance=True)
    except OcrUnavailableError as exc:
        # Rule: a model failure must never be reported as "no currency found".
        logger.error("[Currency] Model error: %s", exc)
        return {
            "success": False,
            "currency": None,
            "denomination": None,
            "confidence": 0.0,
            "error_type": "MODEL_ERROR",
            "evidence": None,
            "full_text": "",
        }

    return decide_currency(boxes)


def decide_currency(boxes) -> dict:
    """Turn recognized text boxes into a currency result.

    Split from :func:`detect_currency` so the evidence rules can be tested
    without paying for OCR inference.
    """
    full_text = "\n".join(box["text"] for box in boxes)
    text = full_text.upper()
    logger.info(
        "[Currency] Raw predictions: %d boxes text=%r", len(boxes), text[:400]
    )

    candidates = _collect_candidates(boxes, text)
    has_note_marker = any(marker in text for marker in NOTE_MARKERS)
    candidates = [
        candidate for candidate in candidates
        if has_note_marker or not candidate["needs_marker"]
    ]

    for candidate in sorted(candidates, key=_candidate_rank):
        logger.info(
            "[Currency] Candidate denomination=%d tier=%d token=%r height=%.0f "
            "ocr_confidence=%.2f evidence=%s",
            candidate["denomination"], candidate["tier"], candidate["token"],
            candidate["height"], candidate["ocr_confidence"], candidate["evidence"],
        )

    if not candidates:
        logger.info(
            "[Currency] No detection: boxes=%d note_marker=%s",
            len(boxes), has_note_marker,
        )
        return {
            "success": False,
            "currency": None,
            "denomination": None,
            "confidence": 0.0,
            "error_type": None,
            "evidence": None,
            "full_text": full_text,
        }

    # A note prints its denomination far larger than its serial/other text, so
    # the biggest matching box is the denomination when several appear.
    best = sorted(candidates, key=_candidate_rank)[0]
    confidence = round(
        min(0.99, _TIER_BASE_CONFIDENCE[best["tier"]] + 0.09 * best["ocr_confidence"]),
        2,
    )
    logger.info(
        "[Currency] Confidence: %.2f | Selected denomination: %d via %s",
        confidence, best["denomination"], best["evidence"],
    )

    return {
        "success": True,
        "currency": "INR",
        "denomination": best["denomination"],
        "confidence": confidence,
        "error_type": None,
        "evidence": best["evidence"],
        "full_text": full_text,
    }


def _candidate_rank(candidate: dict):
    """Strongest evidence first, then the largest printed match."""
    return (
        candidate["tier"],
        -candidate["height"],
        -candidate["ocr_confidence"],
    )


def _collect_candidates(boxes, text: str):
    """Gather every denomination the recognized text supports.

    A candidate may require a note marker before it is trusted; see
    ``needs_marker``.
    """
    candidates = []

    for box in boxes:
        token = _normalize_token(box["text"])
        if not token:
            continue

        match = _RUPEE_NUMBER.match(token)
        if match:
            denomination = _as_denomination(match.group(1))
            if denomination is not None:
                # "R100" needs corroboration; "₹100"/"RS 500"/"RUPEES 200"
                # carry an unambiguous currency marker on their own.
                needs_marker = bool(_AMBIGUOUS_RUPEE.match(token))
                candidates.append(_candidate(
                    denomination, 1, token, box,
                    evidence="printed_amount", needs_marker=needs_marker,
                ))
                continue

        digits = token if token.isdigit() else None
        if digits is not None:
            denomination = _as_denomination(digits)
            if denomination is not None:
                # The large printed numeral alone, e.g. "500".  Requires the
                # note markers so a serial or price cannot match.
                candidates.append(_candidate(
                    denomination, 3, token, box,
                    evidence="printed_numeral", needs_marker=True,
                ))

    # The denomination is also spelled out in words.
    with_currency = bool(re.search(_WORD_WITH_CURRENCY, text))
    for denomination, pattern in _WORD_DENOMINATION.items():
        match = re.search(pattern, text)
        if match:
            candidates.append({
                "denomination": denomination,
                "tier": 2,
                "token": match.group(0),
                "height": _word_height(boxes, pattern),
                "ocr_confidence": 0.9,
                "evidence": "denomination_words",
                # "FIFTY"/"TEN" alone are ordinary words; "... RUPEES" is not.
                "needs_marker": not with_currency,
            })

    return candidates


def _candidate(
    denomination: int,
    tier: int,
    token: str,
    box: dict,
    *,
    evidence: str,
    needs_marker: bool,
) -> dict:
    return {
        "denomination": denomination,
        "tier": tier,
        "token": token,
        "height": box["height"],
        "ocr_confidence": box["confidence"],
        "evidence": evidence,
        "needs_marker": needs_marker,
    }


def _word_height(boxes, pattern: str) -> float:
    """Height of the tallest box whose text matches a denomination word."""
    regex = re.compile(pattern)
    heights = [
        box["height"] for box in boxes
        if regex.search(box["text"].strip().upper())
    ]
    return max(heights) if heights else 0.0


def _normalize_token(raw: str) -> str:
    """Upper-case one recognized box and drop its surrounding punctuation."""
    return raw.strip().strip(".,;:'\"|()[]{}!?*#_-%/").upper()


def _as_denomination(digits: str):
    value = int(digits)
    return value if value in SUPPORTED_DENOMINATIONS else None