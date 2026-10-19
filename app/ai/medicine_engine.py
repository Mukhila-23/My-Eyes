from app.ai.ocr_engine import extract_text


def extract_medicine_details(image_path: str):
    """
    Extract medicine information from an image.
    Version 1: Uses OCR and assumes the first line is the medicine name.
    """

    full_text = extract_text(image_path)

    lines = [
        line.strip()
        for line in full_text.split("\n")
        if line.strip()
    ]

    medicine_name = lines[0] if lines else "Unknown Medicine"

    return {
        "medicine_name": medicine_name,
        "full_text": full_text
    }