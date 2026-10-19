from typing import List, Optional

from pydantic import BaseModel


class NutritionInfo(BaseModel):
    energy: Optional[str] = None
    protein: Optional[str] = None
    carbohydrates: Optional[str] = None
    fat: Optional[str] = None


class ProductReaderResponse(BaseModel):
    product_name: Optional[str] = None
    brand: Optional[str] = None
    net_quantity: Optional[str] = None
    mrp: Optional[str] = None
    manufacturing_date: Optional[str] = None
    expiry_date: Optional[str] = None
    batch_number: Optional[str] = None
    ingredients: List[str] = []
    nutrition: NutritionInfo
    audio_url: str