from fastapi import APIRouter, File, UploadFile, HTTPException

router = APIRouter(
    prefix="/vision",
    tags=["Vision"],
)


@router.post("/process")
async def process_vision(
    mode: str,
    file: UploadFile = File(...),
):
    """
    Common vision endpoint.

    Receives:
        mode -> type of vision operation
        file -> image captured from Flutter
    """

    allowed_modes = {
        "scanObject",
        "readText",
        "medicine",
        "product",
        "currency",
        "scene",
        "objectFinder",
    }

    if mode not in allowed_modes:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported vision mode: {mode}",
        )

    image_bytes = await file.read()

    if not image_bytes:
        raise HTTPException(
            status_code=400,
            detail="Empty image received.",
        )

    return {
        "success": True,
        "mode": mode,
        "message": f"{mode} image received successfully.",
        "result": None,
    }