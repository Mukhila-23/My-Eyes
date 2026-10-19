import re

from app.ai.ocr_engine import extract_text

def extract_manufacturing_date(text: str):
    patterns = [
        r"MFG[:\s]*([0-9]{2}[/-][0-9]{4})",
        r"MANUFACTURED[:\s]*([0-9]{2}[/-][0-9]{4})",
        r"MFD[:\s]*([0-9]{2}[/-][0-9]{4})"
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return match.group(1)

    return None


def extract_expiry_date(text: str):
    patterns = [
        r"EXP[:\s]*([0-9]{2}[/-][0-9]{4})",
        r"EXPIRY[:\s]*([0-9]{2}[/-][0-9]{4})",
        r"BEST BEFORE[:\s]*([0-9]{2}[/-][0-9]{4})"
    ]

    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return match.group(1)

    return None

def extract_ingredients(text: str):
    lines = text.split("\n")

    ingredients = []

    capture = False

    for line in lines:

        upper_line = line.upper().strip()

        # Start capturing after finding "Ingredients"
        if "INGREDIENT" in upper_line:
            capture = True
            continue

        # Stop when another section starts
        if capture:
            if any(keyword in upper_line for keyword in [
                "NUTRITION",
                "ENERGY",
                "PROTEIN",
                "FAT",
                "CARBOHYDRATE",
                "SUGAR",
                "FSSAI",
                "MRP",
                "NET QUANTITY",
                "BATCH",
                "MFG",
                "EXP"
            ]):
                break

            if line.strip():
                ingredients.append(line.strip())

    return ingredients

def extract_nutrition(text: str):

    nutrition = {
        "energy": None,
        "protein": None,
        "carbohydrates": None,
        "fat": None
    }

    patterns = {
        "energy": r"ENERGY\s*[:\-]?\s*([^\n]+)",
        "protein": r"PROTEIN\s*[:\-]?\s*([^\n]+)",
        "carbohydrates": r"CARBOHYDRATE[S]?\s*[:\-]?\s*([^\n]+)",
        "fat": r"FAT\s*[:\-]?\s*([^\n]+)"
    }

    for key, pattern in patterns.items():

        match = re.search(pattern, text, re.IGNORECASE)

        if match:
            nutrition[key] = match.group(1).strip()

    return nutrition

def extract_product_details(image_path: str):

    text = extract_text(image_path)

    lines = [
        line.strip()
        for line in text.split("\n")
        if line.strip()
    ]

    IGNORE_WORDS = [
        "MRP",
        "PRICE",
        "NET",
        "QUANTITY",
        "INGREDIENT",
        "NUTRITION",
        "ENERGY",
        "PROTEIN",
        "FAT",
        "CARBOHYDRATE",
        "MANUFACTURED",
        "MFG",
        "EXPIRY",
        "BEST BEFORE",
        "BATCH",
        "FSSAI",
        "BARCODE"
    ]

    # -------------------------
    # Brand & Product Name
    # -------------------------

    candidate_lines = []

    for line in lines:

        upper_line = line.upper()

        if any(word in upper_line for word in IGNORE_WORDS):
            continue

        if len(line) < 3:
            continue

        candidate_lines.append(line)

    brand = candidate_lines[0] if len(candidate_lines) > 0 else None

    product_name = (
        " ".join(candidate_lines[:3])
        if candidate_lines
        else None
    )

    # -------------------------
    # Net Quantity
    # -------------------------

    quantity_match = re.search(
        r'(\d+(\.\d+)?)\s?(g|kg|ml|l)',
        text,
        re.IGNORECASE
    )

    net_quantity = (
        quantity_match.group(0)
        if quantity_match
        else None
    )

    # -------------------------
    # MRP
    # -------------------------

    mrp_match = re.search(
        r'₹\s?\d+(\.\d+)?',
        text
    )

    mrp = (
        mrp_match.group(0)
        if mrp_match
        else None
    )

    return {
        "product_name": product_name,
        "brand": brand,
        "net_quantity": net_quantity,
        "mrp": mrp,
        "manufacturing_date": extract_manufacturing_date(text),
        "expiry_date": extract_expiry_date(text),
        "batch_number": None,
        "ingredients": extract_ingredients(text),
        "nutrition": extract_nutrition(text)
    }